defmodule BillingCore.ERP.Sync.Builder do
  @moduledoc """
  Builds the adapter-neutral `CanonicalInvoice` from a frozen invoice intent
  plus validated mappings (SPEC §17.4/§17.5, BC-US-080).

  Missing or invalid customer/product mappings block the operation with
  explicit blockers — never a silent fallback (INV-011). The frozen customer
  version snapshot supplies the recipient so later customer-master edits
  cannot rewrite invoice identity (§17.4).
  """

  import Ecto.Query

  alias BillingCore.Billing.InvoiceIntent
  alias BillingCore.Domain.{Money, Period}
  alias BillingCore.ERP.CanonicalInvoice
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.ERP.Connection
  alias BillingCore.Repo

  @doc "Stable external reference (§17.4): `abc:<team-short>:<intent-id>:v<version>`."
  @spec external_reference(InvoiceIntent.t()) :: String.t()
  def external_reference(%InvoiceIntent{} = intent) do
    team_short = intent.team_id |> String.replace("-", "") |> String.slice(0, 8)
    "abc:#{team_short}:#{intent.id}:v#{intent.intent_version}"
  end

  @spec build(InvoiceIntent.t(), Connection.t()) ::
          {:ok, CanonicalInvoice.t()} | {:error, {:blocked, [term()]}}
  def build(%InvoiceIntent{} = intent, %Connection{} = connection) do
    lines = intent.lines |> ensure_loaded(intent) |> Enum.sort_by(& &1.ordinal)

    {customer_number, customer_blockers} = customer_mapping(intent, connection)
    {recipient, recipient_blockers} = recipient_snapshot(intent)
    {product_numbers, product_blockers} = product_mappings(intent, connection, lines)
    settings = team_settings(intent.team_id)

    blockers = customer_blockers ++ recipient_blockers ++ product_blockers

    if blockers != [] do
      {:error, {:blocked, blockers}}
    else
      canonical_lines =
        Enum.map(lines, fn line ->
          %Line{
            order: line.ordinal,
            line_key: line.line_key,
            product_external_id: Map.fetch!(product_numbers, line.product_id),
            description: line.description,
            amount: Money.new!(line.currency, line.amount_minor),
            recognition: recognition(line),
            source_quantity: line.quantity,
            source_unit: line.display_unit
          }
        end)

      {:ok,
       %CanonicalInvoice{
         external_reference: external_reference(intent),
         document_type: document_type(intent.document_kind),
         customer_external_id: customer_number,
         recipient: recipient,
         invoice_date: intent.invoice_date,
         currency: intent.currency,
         payment_term_external_id: settings["erp_payment_term_id"],
         layout_external_id: settings["erp_layout_id"],
         delivery_mode: :none,
         lines: canonical_lines
       }}
    end
  end

  @doc "Delivery mode from team settings, defaulting to `:none` (BC-US-085)."
  @spec delivery_mode(Connection.t()) :: :none | :email | :einvoice
  def delivery_mode(%Connection{team_id: team_id}) do
    case team_settings(team_id)["erp_delivery_mode"] do
      "email" -> :email
      "einvoice" -> :einvoice
      _ -> :none
    end
  end

  defp customer_mapping(intent, connection) do
    mapping =
      Repo.one(
        from m in "customer_erp_mappings",
          prefix: "billing",
          where:
            m.team_id == type(^intent.team_id, Ecto.UUID) and
              m.customer_id == type(^intent.customer_id, Ecto.UUID) and
              m.erp_connection_id == type(^connection.id, Ecto.UUID),
          select: %{number: m.external_customer_number, status: m.validation_status}
      )

    case mapping do
      nil -> {nil, [:customer_mapping_missing]}
      %{status: "invalid"} -> {nil, [:customer_mapping_invalid]}
      %{number: number} -> {number, []}
    end
  end

  defp recipient_snapshot(intent) do
    version =
      Repo.one(
        from v in "customer_versions",
          prefix: "billing",
          where:
            v.team_id == type(^intent.team_id, Ecto.UUID) and
              v.customer_id == type(^intent.customer_id, Ecto.UUID) and
              v.version == ^intent.customer_version,
          select: %{
            legal_name: v.legal_name,
            address_line: v.address_line,
            zip: v.zip,
            city: v.city,
            country: v.country,
            email: v.email,
            vat_number: v.vat_number
          }
      )

    case version do
      nil ->
        {nil, [:customer_version_missing]}

      snapshot ->
        {%{
           legal_name: snapshot.legal_name,
           address: snapshot.address_line,
           zip: snapshot.zip,
           city: snapshot.city,
           country: snapshot.country,
           email: snapshot.email,
           vat_number: snapshot.vat_number
         }, []}
    end
  end

  defp product_mappings(intent, connection, lines) do
    product_ids = lines |> Enum.map(& &1.product_id) |> Enum.uniq()

    rows =
      Repo.all(
        from m in "product_erp_mappings",
          prefix: "billing",
          where:
            m.team_id == type(^intent.team_id, Ecto.UUID) and
              m.erp_connection_id == type(^connection.id, Ecto.UUID) and
              m.product_id in type(^product_ids, {:array, Ecto.UUID}),
          select: {m.product_id, m.external_product_number, m.validation_status}
      )

    numbers =
      Map.new(rows, fn {product_id, number, _status} -> {Ecto.UUID.cast!(product_id), number} end)

    invalid =
      rows
      |> Enum.filter(fn {_id, _n, status} -> status == "invalid" end)
      |> Enum.map(fn {id, _n, _s} -> {:product_mapping_invalid, Ecto.UUID.cast!(id)} end)

    missing =
      product_ids
      |> Enum.reject(&Map.has_key?(numbers, &1))
      |> Enum.map(&{:product_mapping_missing, &1})

    {numbers, invalid ++ missing}
  end

  defp team_settings(team_id) do
    settings =
      Repo.one(
        from t in "teams",
          prefix: "billing",
          join: v in "team_settings_versions",
          prefix: "billing",
          on: v.team_id == t.id and v.version == t.settings_version,
          where: t.id == type(^team_id, Ecto.UUID),
          select: v.settings
      )

    settings || %{}
  end

  defp document_type("invoice"), do: :invoice
  defp document_type("credit_note"), do: :credit_note

  defp recognition(line) do
    case line.recognition_mode do
      "point_in_time" -> :point_in_time
      "over_time" -> {:over_time, Period.new!(line.service_start, line.service_end_exclusive)}
    end
  end

  defp ensure_loaded(%Ecto.Association.NotLoaded{}, intent) do
    Repo.all(
      from l in BillingCore.Billing.InvoiceLine,
        where: l.invoice_intent_id == ^intent.id,
        order_by: l.ordinal
    )
  end

  defp ensure_loaded(lines, _intent) when is_list(lines), do: lines
end
