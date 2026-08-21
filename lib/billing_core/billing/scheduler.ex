defmodule BillingCore.Billing.Scheduler do
  @moduledoc """
  Billing run creation and processing (SPEC §18, BC-US-034/054/066).

  One run exists per deterministic run key (`<date>:regular:<tz>`); the
  database unique constraint prevents duplicates. Subscription selection is
  stable-ordered; each subscription/period/component occurrence is protected
  by an advisory lock during calculation and by the unique active-occurrence
  constraint on charges (§18.3–18.4). Charges for one customer consolidate
  into one invoice intent per team/connection/customer/currency/invoice-date
  (BC-US-066).
  """

  import Ecto.Query

  alias BillingCore.{Billing, Repo, Scope}
  alias BillingCore.Billing.{BillingRun, Preview}
  alias BillingCore.Contracts.Subscription

  @doc """
  Opens (or returns) the regular run for `team` scope on `invoice_date` and
  rates every eligible subscription, freezing one intent per customer.

  Returns `{:ok, %{run: run, invoiced: [intent], skipped: skipped}}`.
  `skipped` maps subscription IDs to reasons (blockers, already billed, or
  no billable period boundary on this date).
  """
  @spec process_regular_run(Scope.t(), Date.t()) ::
          {:ok, %{run: BillingRun.t(), invoiced: list(), skipped: map()}} | {:error, term()}
  def process_regular_run(%Scope{} = scope, %Date{} = invoice_date) do
    team = scope.team
    run_key = "#{invoice_date}:regular:#{String.replace(team.time_zone, "/", "-")}"

    with {:ok, run} <-
           Billing.open_run(scope, %{
             run_key: run_key,
             invoice_date: invoice_date,
             usage_cutoff: usage_cutoff(team, invoice_date),
             settings_version: team.settings_version
           }) do
      {previews, skipped} = collect_previews(scope, invoice_date)

      {intents, more_skipped} = freeze_by_customer(scope, run, previews)

      {:ok, %{run: run, invoiced: intents, skipped: Map.merge(skipped, more_skipped)}}
    end
  end

  @doc """
  Subscriptions eligible for the run date (§18.2): active (or
  pending-cancellation) with a billing boundary on the run date, stable
  ordering by customer, subscription, external id.
  """
  @spec eligible_subscriptions(Scope.t(), Date.t()) :: [Subscription.t()]
  def eligible_subscriptions(%Scope{} = scope, %Date{} = invoice_date) do
    team_id = Scope.team_id!(scope)

    Repo.all(
      from s in Subscription,
        join: c in "contracts",
        prefix: "billing",
        on: c.id == s.contract_id,
        where: s.team_id == ^team_id,
        where: s.status in [:active, :pending_cancellation],
        where: s.start_date <= ^invoice_date,
        where: is_nil(s.end_date_exclusive) or s.end_date_exclusive > ^invoice_date,
        order_by: [asc: c.customer_id, asc: s.id]
    )
  end

  ## Internals

  defp collect_previews(scope, invoice_date) do
    scope
    |> eligible_subscriptions(invoice_date)
    |> Enum.reduce({[], %{}}, fn subscription, {previews, skipped} ->
      case preview_if_boundary(scope, subscription, invoice_date) do
        {:ok, preview} -> {previews ++ [{subscription, preview}], skipped}
        {:skip, reason} -> {previews, Map.put(skipped, subscription.id, reason)}
      end
    end)
  end

  defp preview_if_boundary(scope, subscription, invoice_date) do
    case Preview.for_subscription(scope, subscription.id, invoice_date) do
      {:ok, %Preview{billing_timing: :in_arrears}} ->
        # In-arrears plans bill the period ENDING at the run date
        # (BC-US-015): rate the previous period with usage evidence through
        # the run cutoff.
        arrears_preview(scope, subscription, invoice_date)

      {:ok, %Preview{} = preview} ->
        check_boundary(preview, fn p -> p.billing_period.start_date == invoice_date end)

      {:error, reason} ->
        {:skip, {:error, reason}}
    end
  end

  defp arrears_preview(scope, subscription, invoice_date) do
    if Date.before?(subscription.start_date, invoice_date) do
      case Preview.for_subscription(scope, subscription.id, Date.add(invoice_date, -1)) do
        {:ok, %Preview{} = preview} ->
          check_boundary(preview, fn p ->
            p.billing_period.end_date_exclusive == invoice_date
          end)

        {:error, reason} ->
          {:skip, {:error, reason}}
      end
    else
      {:skip, :not_a_billing_boundary}
    end
  end

  defp check_boundary(preview, boundary_fun) do
    cond do
      preview.blockers != [] -> {:skip, {:blocked, preview.blockers}}
      preview.lines == [] -> {:skip, :nothing_to_bill}
      not boundary_fun.(preview) -> {:skip, :not_a_billing_boundary}
      true -> {:ok, preview}
    end
  end

  defp freeze_by_customer(scope, run, previews) do
    previews
    |> Enum.group_by(fn {_sub, preview} -> {preview.customer_id, preview.currency} end)
    |> Enum.sort_by(fn {{customer_id, currency}, _} -> {customer_id, currency} end)
    |> Enum.reduce({[], %{}}, fn {{_customer_id, _currency}, group}, {intents, skipped} ->
      case freeze_group(scope, run, group) do
        {:ok, intent} ->
          {intents ++ [intent], skipped}

        {:skip, reasons} ->
          {intents, Map.merge(skipped, reasons)}
      end
    end)
  end

  defp freeze_group(scope, run, group) do
    {_first_sub, first_preview} = hd(group)

    Repo.transaction(fn ->
      # §18.3 advisory locks per subscription-period-component key.
      recorded =
        Enum.flat_map(group, fn {subscription, preview} ->
          Enum.flat_map(preview.lines, fn line ->
            record_line_charge(scope, run, subscription, preview, line)
          end)
        end)

      case recorded do
        [] ->
          Repo.rollback(Map.new(group, fn {sub, _} -> {sub.id, :occurrence_already_billed} end))

        lines ->
          combined =
            lines
            |> Enum.with_index()
            |> Enum.map(fn {line, idx} -> %{line | ordinal: idx} end)

          {:ok, intent} =
            Billing.freeze_invoice_intent(scope, %{
              customer_id: first_preview.customer_id,
              customer_version: first_preview.customer_version,
              customer_external_id: first_preview.customer_external_id,
              customer_legal_name: first_preview.customer_legal_name,
              contract_id: first_preview.contract_id,
              billing_run_id: run.id,
              currency: first_preview.currency,
              invoice_date: run.invoice_date,
              usage_cutoff: run.usage_cutoff,
              lines: combined
            })

          intent
      end
    end)
    |> case do
      {:ok, intent} -> {:ok, intent}
      {:error, reasons} when is_map(reasons) -> {:skip, reasons}
    end
  end

  defp record_line_charge(scope, run, subscription, preview, line) do
    occurrence_key =
      Enum.join(
        [
          subscription.id,
          component_code(line.line_key),
          line.service_start || run.invoice_date,
          line.service_end_exclusive || run.invoice_date,
          charge_kind(line)
        ],
        ":"
      )

    advisory_lock!(occurrence_key)

    case Billing.record_charge!(scope, %{
           team_id: preview_team_id(scope),
           billing_run_id: run.id,
           subscription_id: subscription.id,
           price_component_id: nil,
           component_code: component_code(line.line_key),
           product_id: line.product_id,
           product_version: line.product_version,
           charge_kind: charge_kind(line),
           occurrence_key: occurrence_key,
           currency: preview.currency,
           amount_minor: line.amount_minor,
           unrounded: to_string(line.amount_minor),
           quantity: line.quantity,
           recognition_mode: to_string(line.recognition_mode),
           service_start: line.service_start,
           service_end_exclusive: line.service_end_exclusive,
           calculation_trace: line.calculation_trace
         }) do
      {:ok, charge} ->
        [Map.put(line, :source_charge_id, charge.id)]

      {:error, :occurrence_already_billed} ->
        []
    end
  end

  defp advisory_lock!(key) do
    <<lock::signed-64, _rest::binary>> = :crypto.hash(:sha256, key)
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock])
  end

  defp component_code("subscription:" <> rest) do
    case String.split(rest, ":") do
      [_sub, "component", code | _] -> code
      _ -> "unknown"
    end
  end

  defp component_code(key), do: key

  defp charge_kind(%{amount_minor: amount}) when amount < 0, do: "adjustment_credit"
  defp charge_kind(_line), do: "recurring"

  defp preview_team_id(scope), do: Scope.team_id!(scope)

  defp usage_cutoff(team, invoice_date) do
    case DateTime.new(invoice_date, ~T[00:00:00.000000], team.time_zone) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _before, after_dt} -> DateTime.shift_zone!(after_dt, "Etc/UTC")
      {:error, _} -> DateTime.new!(invoice_date, ~T[00:00:00.000000], "Etc/UTC")
    end
  end
end
