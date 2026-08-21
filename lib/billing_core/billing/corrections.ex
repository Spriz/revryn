defmodule BillingCore.Billing.Corrections do
  @moduledoc """
  Post-booking corrections through compensating credit documents
  (SPEC INV-001/002, BC-US-102/103/104).

  A booked invoice is never mutated. A correction opens a case linking the
  original intent, a credit intent (exact or partial negatives of the
  original normalized lines, preserving product mapping, service period, and
  recognition mode), and optionally a replacement intent. Credit intents flow
  through the normal draft → approval → booking states.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Billing, Outbox, Repo, Scope}
  alias BillingCore.Billing.{InvoiceIntent, InvoiceLine}

  defmodule Case do
    @moduledoc false
    use Ecto.Schema

    @schema_prefix "billing"
    @primary_key {:id, Ecto.UUID, autogenerate: true}
    @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]
    schema "correction_cases" do
      field :team_id, Ecto.UUID
      field :original_invoice_intent_id, Ecto.UUID
      field :original_booked_number, :string
      field :credit_invoice_intent_id, Ecto.UUID
      field :replacement_invoice_intent_id, Ecto.UUID
      field :reason_code, :string
      field :narrative, :string
      field :status, :string, default: "open"
      field :created_by, :string
      timestamps()
    end
  end

  @doc """
  Credits a booked invoice in full (BC-US-102): every line is exactly
  negated. Returns `{:ok, %{case: case, credit_intent: intent}}`.
  """
  @spec create_full_credit(Scope.t(), InvoiceIntent.t(), keyword()) ::
          {:ok, %{case: Case.t(), credit_intent: InvoiceIntent.t()}} | {:error, term()}
  def create_full_credit(%Scope{} = scope, %InvoiceIntent{} = intent, opts \\ []) do
    lines = original_lines(intent)
    allocations = Enum.map(lines, &{&1.line_key, &1.amount_minor})
    create_credit(scope, intent, allocations, opts)
  end

  @doc """
  Credits selected amounts of a booked invoice (BC-US-103). `allocations` are
  `{line_key, positive_minor_units}` pairs; cumulative credits per line may
  never exceed the original line amount.
  """
  @spec create_partial_credit(
          Scope.t(),
          InvoiceIntent.t(),
          [{String.t(), pos_integer()}],
          keyword()
        ) ::
          {:ok, %{case: Case.t(), credit_intent: InvoiceIntent.t()}} | {:error, term()}
  def create_partial_credit(%Scope{} = scope, %InvoiceIntent{} = intent, allocations, opts \\ []) do
    create_credit(scope, intent, allocations, opts)
  end

  @doc """
  Credit and rebill (BC-US-104): full credit of the booked invoice plus a
  replacement intent with the corrected lines, linked through one correction
  case. The replacement follows the normal draft/approval/booking states and
  should not book before the credit draft exists (finance policy enforces
  ordering at approval time).
  """
  @spec create_credit_and_rebill(Scope.t(), InvoiceIntent.t(), [map()], keyword()) ::
          {:ok,
           %{
             case: Case.t(),
             credit_intent: InvoiceIntent.t(),
             replacement_intent: InvoiceIntent.t()
           }}
          | {:error, term()}
  def create_credit_and_rebill(
        %Scope{} = scope,
        %InvoiceIntent{} = intent,
        replacement_lines,
        opts \\ []
      ) do
    with {:ok, %{case: correction_case, credit_intent: credit_intent}} <-
           create_full_credit(scope, intent, opts) do
      Repo.transaction(fn ->
        {:ok, replacement} =
          Billing.freeze_invoice_intent(scope, %{
            customer_id: intent.customer_id,
            customer_version: intent.customer_version,
            customer_external_id: snapshot_customer(intent, "externalId"),
            customer_legal_name: snapshot_customer(intent, "legalName"),
            contract_id: intent.contract_id,
            currency: intent.currency,
            invoice_date: Keyword.get(opts, :invoice_date, Date.utc_today()),
            usage_cutoff: snapshot_cutoff(intent),
            lines: replacement_lines
          })

        updated_case =
          correction_case
          |> Ecto.Changeset.change(replacement_invoice_intent_id: replacement.id)
          |> Repo.update!()

        Audit.record!(scope, "billing.correction.rebill_created",
          aggregate: {:correction_case, updated_case.id},
          payload: %{replacement_invoice_intent_id: replacement.id}
        )

        %{case: updated_case, credit_intent: credit_intent, replacement_intent: replacement}
      end)
    end
  end

  @doc """
  Completes a correction case once its credit (and replacement, when present)
  are booked; emits `correction_case.completed.v1`.
  """
  @spec complete_case(Scope.t(), Case.t()) :: {:ok, Case.t()} | {:error, term()}
  def complete_case(%Scope{} = scope, %Case{} = correction_case) do
    with :ok <- authorize(scope),
         :ok <- ensure_team(scope, correction_case.team_id),
         :ok <- ensure_documents_booked(correction_case) do
      {:ok, completed} =
        Repo.transaction(fn ->
          completed =
            correction_case
            |> Ecto.Changeset.change(status: "completed")
            |> Repo.update!()

          Audit.record!(scope, "billing.correction.completed",
            aggregate: {:correction_case, completed.id}
          )

          Outbox.emit!("correction_case.completed.v1",
            aggregate: {:correction_case, completed.id},
            team_id: completed.team_id,
            correlation_id: scope.correlation_id,
            payload: %{original_invoice_intent_id: completed.original_invoice_intent_id}
          )

          completed
        end)

      {:ok, completed}
    end
  end

  defp ensure_documents_booked(correction_case) do
    intent_ids =
      [correction_case.credit_invoice_intent_id, correction_case.replacement_invoice_intent_id]
      |> Enum.reject(&is_nil/1)

    unbooked =
      Repo.all(
        from l in "invoice_intent_lifecycle",
          prefix: "billing",
          where: l.invoice_intent_id in type(^intent_ids, {:array, Ecto.UUID}),
          where: l.current_state != "erp_booked",
          select: l.invoice_intent_id
      )

    if unbooked == [], do: :ok, else: {:error, {:documents_not_booked, length(unbooked)}}
  end

  @doc "Correction cases for a team, newest first."
  @spec list_cases(Scope.t()) :: [Case.t()]
  def list_cases(%Scope{} = scope) do
    team_id = Scope.team_id!(scope)

    Repo.all(from c in Case, where: c.team_id == ^team_id, order_by: [desc: c.created_at])
  end

  ## Internals

  defp create_credit(scope, intent, allocations, opts) do
    with :ok <- authorize(scope),
         :ok <- ensure_team(scope, intent.team_id),
         :ok <- ensure_booked(intent),
         lines = original_lines(intent),
         {:ok, credit_lines} <- build_credit_lines(intent, lines, allocations) do
      Repo.transaction(fn ->
        case Billing.transition_intent(scope, intent, :correction_approved,
               reason: opts[:reason_code] || "correction"
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        {:ok, credit_intent} =
          Billing.freeze_invoice_intent(scope, %{
            customer_id: intent.customer_id,
            customer_version: intent.customer_version,
            customer_external_id: snapshot_customer(intent, "externalId"),
            customer_legal_name: snapshot_customer(intent, "legalName"),
            contract_id: intent.contract_id,
            currency: intent.currency,
            invoice_date: Keyword.get(opts, :invoice_date, Date.utc_today()),
            usage_cutoff: snapshot_cutoff(intent),
            document_kind: "credit_note",
            lines: credit_lines
          })

        correction_case =
          Repo.insert!(%Case{
            team_id: intent.team_id,
            original_invoice_intent_id: intent.id,
            original_booked_number: booked_number(intent),
            credit_invoice_intent_id: credit_intent.id,
            reason_code: Keyword.get(opts, :reason_code, "correction"),
            narrative: opts[:narrative],
            status: "credit_pending",
            created_by: actor_id(scope)
          })

        case Billing.transition_intent(scope, intent, :correction_case_created,
               reason: correction_case.id
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        Audit.record!(scope, "billing.correction.opened",
          aggregate: {:correction_case, correction_case.id},
          payload: %{
            original_invoice_intent_id: intent.id,
            credit_invoice_intent_id: credit_intent.id
          }
        )

        Outbox.emit!("correction_case.opened.v1",
          aggregate: {:correction_case, correction_case.id},
          team_id: intent.team_id,
          correlation_id: scope.correlation_id,
          payload: %{original_invoice_intent_id: intent.id}
        )

        %{case: correction_case, credit_intent: credit_intent}
      end)
    end
  end

  defp build_credit_lines(intent, lines, allocations) do
    by_key = Map.new(lines, &{&1.line_key, &1})
    prior = prior_credits_by_line(intent)

    allocations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{line_key, amount}, ordinal}, {:ok, acc} ->
      case Map.fetch(by_key, line_key) do
        :error ->
          {:halt, {:error, {:unknown_line, line_key}}}

        {:ok, line} ->
          already = Map.get(prior, line.id, 0)

          cond do
            not is_integer(amount) or amount <= 0 ->
              {:halt, {:error, {:invalid_credit_amount, line_key}}}

            already + amount > line.amount_minor ->
              {:halt,
               {:error,
                {:credit_exceeds_original, line_key,
                 %{original: line.amount_minor, already_credited: already, requested: amount}}}}

            true ->
              {:cont, {:ok, acc ++ [credit_line(line, amount, ordinal)]}}
          end
      end
    end)
  end

  defp credit_line(line, amount, ordinal) do
    %{
      line_key: "credit:#{line.line_key}",
      product_id: line.product_id,
      product_version: line.product_version,
      description: "Credit: #{line.description}",
      quantity: line.quantity,
      amount_minor: -amount,
      recognition_mode: line.recognition_mode,
      service_start: line.service_start,
      service_end_exclusive: line.service_end_exclusive,
      calculation_trace: %{
        "kind" => "credit",
        "source_line_id" => line.id,
        "source_amount_minor" => line.amount_minor,
        "credited_minor" => amount
      },
      adjusts_line_id: line.id,
      ordinal: ordinal
    }
  end

  # Sum of prior credit allocations per original line across all credit
  # intents that reference this original intent's lines (BC-US-103).
  defp prior_credits_by_line(intent) do
    line_ids = original_lines(intent) |> Enum.map(& &1.id)

    Repo.all(
      from l in InvoiceLine,
        join: i in InvoiceIntent,
        on: i.id == l.invoice_intent_id,
        join: lc in "invoice_intent_lifecycle",
        prefix: "billing",
        on: lc.invoice_intent_id == i.id,
        where: l.adjusts_line_id in ^line_ids,
        where: i.document_kind == "credit_note",
        where: lc.current_state != "superseded",
        select: {l.adjusts_line_id, l.amount_minor}
    )
    |> Enum.reduce(%{}, fn {line_id, amount}, acc ->
      Map.update(acc, line_id, -amount, &(&1 - amount))
    end)
  end

  defp original_lines(intent) do
    case intent.lines do
      %Ecto.Association.NotLoaded{} ->
        Repo.all(
          from l in InvoiceLine, where: l.invoice_intent_id == ^intent.id, order_by: l.ordinal
        )

      lines ->
        Enum.sort_by(lines, & &1.ordinal)
    end
  end

  defp ensure_booked(intent) do
    if Billing.intent_state(intent) == "erp_booked", do: :ok, else: {:error, :not_booked}
  end

  defp booked_number(intent) do
    Repo.one(
      from d in "erp_documents",
        prefix: "billing",
        where: d.invoice_intent_id == type(^intent.id, Ecto.UUID),
        select: d.external_booked_number,
        limit: 1
    )
  end

  defp snapshot_customer(intent, key) do
    get_in(intent.canonical_snapshot, ["customer", key]) || "unknown"
  end

  defp snapshot_cutoff(intent) do
    case intent.canonical_snapshot["usageCutoff"] do
      nil ->
        DateTime.utc_now()

      cutoff ->
        {:ok, dt, _} = DateTime.from_iso8601(cutoff)
        dt
    end
  end

  defp authorize(%Scope{} = scope) do
    if Scope.has_team_role?(scope, [:finance_operator]), do: :ok, else: {:error, :unauthorized}
  end

  defp ensure_team(%Scope{} = scope, team_id) do
    if Scope.team_id!(scope) == team_id, do: :ok, else: {:error, :unauthorized}
  end

  defp actor_id(%Scope{user: %{id: id}}), do: to_string(id)
  defp actor_id(%Scope{service_credential: %{id: id}}), do: to_string(id)
  defp actor_id(_), do: nil
end
