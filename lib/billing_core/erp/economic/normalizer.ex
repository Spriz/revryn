defmodule BillingCore.ERP.Economic.Normalizer do
  @moduledoc """
  Deterministic normalization of e-conomic draft/booked invoice payloads into
  `BillingCore.ERP.Document` (SPEC §17.14).

  Input payloads must be decoded with `Jason.decode(..., floats: :decimals)`
  (as `BillingCore.ERP.Economic.Client` does) so monetary provider numbers
  arrive as `Decimal`s — this module rejects binary floats outright (INV-006).

  Normalization rules:

    * lines sort by provider `sortKey`; the normalized `order` is the 0-based
      position after sorting (provider renumbering is a reconciliation
      warning, not a normalization concern — SPEC §17.15);
    * line amount is `unitNetPrice × quantity` converted exactly to integer
      minor units at the currency scale;
    * a line without `accrual` is `:point_in_time`; a line with accrual dates
      converts the provider's inclusive `endDate` back to the canonical
      exclusive end (`endDate + 1 day` — SPEC §17.5, INV-007);
    * provider-generated VAT, gross totals, booked number, and PDF link are
      recorded in `provider_extras` and excluded from the content hash
      (SPEC §17.14, §17.15 informational);
    * `external_hash` is `BillingCore.Domain.Canonical.hash/1` over the
      normalized matching-relevant content, so it is stable across provider
      formatting noise.
  """

  alias BillingCore.Domain.{Canonical, Money}
  alias BillingCore.ERP.{Document, Fingerprint}

  @doc """
  Normalizes a provider invoice payload (string-keyed map) into a
  `BillingCore.ERP.Document` with the given `state`.
  """
  @spec normalize(map(), :draft | :booked) :: Document.t()
  def normalize(payload, state) when is_map(payload) and state in [:draft, :booked] do
    currency = Map.fetch!(payload, "currency")

    document = %Document{
      state: state,
      external_draft_id: stringify(payload["draftInvoiceNumber"]),
      external_booked_number: stringify(payload["bookedInvoiceNumber"]),
      external_reference: get_in(payload, ["references", "other"]),
      customer_external_id: stringify(get_in(payload, ["customer", "customerNumber"])),
      recipient_fingerprint: recipient_fingerprint(payload["recipient"]),
      invoice_date: Date.from_iso8601!(Map.fetch!(payload, "date")),
      currency: currency,
      payment_term_external_id:
        stringify(get_in(payload, ["paymentTerms", "paymentTermsNumber"])),
      layout_external_id: stringify(get_in(payload, ["layout", "layoutNumber"])),
      lines: normalize_lines(payload["lines"] || [], currency),
      provider_extras: provider_extras(payload)
    }

    %{document | external_hash: external_hash(document)}
  end

  # -- lines ------------------------------------------------------------------

  defp normalize_lines(lines, currency) when is_list(lines) do
    lines
    |> Enum.sort_by(&line_sort_key/1)
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      description = line["description"]

      %{
        order: index,
        product_external_id: stringify(get_in(line, ["product", "productNumber"])),
        amount: line_amount(line, currency),
        description: description,
        description_fingerprint: Fingerprint.description(description),
        recognition: recognition(line["accrual"])
      }
    end)
  end

  defp line_sort_key(line), do: {line["sortKey"] || 0, line["lineNumber"] || 0}

  # Exact conversion to integer minor units — parsed via Decimal, never float
  # (SPEC §17.14; the trailing round only defends against a provider sending
  # more precision than the currency scale).
  defp line_amount(line, currency) do
    unit_net_price = to_decimal(line["unitNetPrice"] || 0)
    quantity = to_decimal(line["quantity"] || 1)
    scale = Money.exponent(currency)

    minor_units =
      unit_net_price
      |> Decimal.mult(quantity)
      |> Decimal.mult(Decimal.new(Integer.pow(10, scale)))
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()

    Money.new!(currency, minor_units)
  end

  defp recognition(%{"startDate" => start_date, "endDate" => end_date})
       when is_binary(start_date) and is_binary(end_date) do
    start = Date.from_iso8601!(start_date)
    end_exclusive = end_date |> Date.from_iso8601!() |> Date.add(1)
    {:over_time, start, end_exclusive}
  end

  defp recognition(_absent_or_incomplete), do: :point_in_time

  # -- recipient --------------------------------------------------------------

  defp recipient_fingerprint(recipient) when is_map(recipient) do
    Fingerprint.recipient(%{
      legal_name: recipient["name"],
      address: recipient["address"],
      zip: recipient["zip"],
      city: recipient["city"],
      country: recipient["country"],
      email: recipient["email"],
      vat_number: recipient["cvr"],
      vat_zone_external_id: stringify(get_in(recipient, ["vatZone", "vatZoneNumber"]))
    })
  end

  defp recipient_fingerprint(_absent), do: nil

  # -- extras and hash --------------------------------------------------------

  defp provider_extras(payload) do
    %{}
    |> put_present(:vat_amount, decimal_or_nil(payload["vatAmount"]))
    |> put_present(:gross_amount, decimal_or_nil(payload["grossAmount"]))
    |> put_present(:booked_invoice_number, stringify(payload["bookedInvoiceNumber"]))
    |> put_present(:pdf_url, get_in(payload, ["pdf", "download"]))
  end

  defp external_hash(%Document{} = document) do
    Canonical.hash(%{
      state: document.state,
      external_reference: document.external_reference,
      customer_external_id: document.customer_external_id,
      recipient_fingerprint: document.recipient_fingerprint,
      invoice_date: document.invoice_date,
      currency: document.currency,
      payment_term_external_id: document.payment_term_external_id,
      layout_external_id: document.layout_external_id,
      lines: Enum.map(document.lines, &hash_line/1)
    })
  end

  defp hash_line(line) do
    %{
      order: line.order,
      product_external_id: line.product_external_id,
      amount: line.amount,
      description_fingerprint: line.description_fingerprint,
      recognition: recognition_map(line.recognition)
    }
  end

  defp recognition_map(:point_in_time), do: %{mode: :point_in_time}

  defp recognition_map({:over_time, start, end_exclusive}) do
    %{mode: :over_time, start_date: start, end_date_exclusive: end_exclusive}
  end

  # -- small helpers ----------------------------------------------------------

  defp to_decimal(%Decimal{} = decimal), do: decimal
  defp to_decimal(integer) when is_integer(integer), do: Decimal.new(integer)
  defp to_decimal(binary) when is_binary(binary), do: Decimal.new(binary)

  defp to_decimal(float) when is_float(float) do
    raise ArgumentError,
          "binary floats are prohibited in provider payloads (INV-006); " <>
            "decode with Jason floats: :decimals"
  end

  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(value), do: to_decimal(value)

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(%Decimal{} = decimal), do: Canonical.decimal_string(decimal)
  defp stringify(value), do: to_string(value)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
