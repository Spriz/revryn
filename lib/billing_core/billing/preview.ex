defmodule BillingCore.Billing.Preview do
  @moduledoc """
  Deterministic invoice preview for a subscription (SPEC BC-US-068, §7.1).

  A preview rates the subscription's current plan-version components for the
  billing period containing `as_of`, applies assigned discounts, and returns
  freeze-ready lines with full calculation traces. It performs no writes and
  no external calls; the fingerprint is stable for unchanged inputs but may
  change when source data changes.

  Fixed recurring components prorate over the active period; metered
  components aggregate frozen usage evidence at the preview's cutoff
  (BC-US-053/055) including §18.5 prior-period carry-forward; one-time
  components bill through charge instances instead. Available customer
  credit is planned automatically (BC-US-108) and finalized at freeze.
  """

  import Ecto.Query

  alias BillingCore.{Catalog, Contracts, Repo, Scope}
  alias BillingCore.Domain.{Canonical, Money, Period}
  alias BillingCore.ERP.Description
  alias BillingCore.Pricing.{Discounts, EligibleLine, Engine, RatingRequest}
  alias BillingCore.Pricing.Model.{FixedRecurring, OneTime}

  defstruct [
    :subscription_id,
    :customer_id,
    :customer_version,
    :customer_external_id,
    :customer_legal_name,
    :contract_id,
    :currency,
    :invoice_date,
    :billing_period,
    :billing_timing,
    :lines,
    :net_amount_minor,
    :fingerprint,
    credit_available_minor: 0,
    credit_planned_minor: 0,
    amount_due_minor: 0,
    credit_account: nil,
    blockers: []
  ]

  @type t :: %__MODULE__{}

  @doc """
  Builds a preview for the billing period containing `as_of`. Returns
  `{:ok, preview}`; blocking conditions land in `preview.blockers` (an empty
  list means the preview is freezable).
  """
  @spec for_subscription(Scope.t(), Ecto.UUID.t(), Date.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def for_subscription(%Scope{} = scope, subscription_id, %Date{} = as_of, opts \\ []) do
    with {:ok, subscription} <- Contracts.get_subscription(scope, subscription_id),
         {:ok, sub_version} <- current_subscription_version(scope, subscription, as_of),
         {:ok, plan_version} <-
           Catalog.get_published_plan_version(scope, sub_version.plan_version_id),
         {:ok, contract} <- Contracts.get_contract(scope, subscription.contract_id),
         {:ok, customer} <- Contracts.get_customer(scope, contract.customer_id) do
      billing_period = billing_period(subscription, plan_version, as_of)
      active_period = active_period(subscription, billing_period)

      {:ok, component_models} = Catalog.fetch_pricing_models(plan_version)
      product_names = product_names(scope, component_models)

      usage_cutoff = Keyword.get_lazy(opts, :usage_cutoff, &DateTime.utc_now/0)

      ctx = %{
        scope: scope,
        subscription: subscription,
        plan_version: plan_version,
        sub_version: sub_version,
        billing_period: billing_period,
        active_period: active_period,
        product_names: product_names,
        usage_cutoff: usage_cutoff
      }

      {charge_lines, blockers} = rate_components(component_models, ctx)

      discount_structs = discount_structs(scope, subscription, contract)
      {lines, net} = apply_discounts(charge_lines, discount_structs, plan_version.currency)

      {credit_account, credit_available} =
        credit_availability(scope, customer, plan_version.currency)

      credit_planned = min(credit_available, max(net, 0))

      preview = %__MODULE__{
        subscription_id: subscription.id,
        customer_id: customer.id,
        customer_version: customer.current_version,
        customer_external_id: customer.external_id,
        customer_legal_name: customer_legal_name(customer),
        contract_id: contract.id,
        currency: plan_version.currency,
        invoice_date: as_of,
        billing_period: billing_period,
        billing_timing: plan_version.billing_timing,
        lines: lines,
        net_amount_minor: net,
        fingerprint: nil,
        credit_available_minor: credit_available,
        credit_planned_minor: credit_planned,
        amount_due_minor: net - credit_planned,
        credit_account: credit_account,
        blockers: blockers
      }

      {:ok, %{preview | fingerprint: fingerprint(preview)}}
    end
  end

  @doc """
  Freezes a blocker-free preview into immutable invoice intent
  (BC-US-069). `opts` may carry `:billing_run_id` and `:usage_cutoff`.
  """
  @spec freeze(Scope.t(), t(), keyword()) ::
          {:ok, BillingCore.Billing.InvoiceIntent.t()} | {:error, term()}
  def freeze(%Scope{} = scope, %__MODULE__{} = preview, opts \\ []) do
    if preview.blockers != [] do
      {:error, {:blocked, preview.blockers}}
    else
      BillingCore.Billing.freeze_invoice_intent(scope, %{
        customer_id: preview.customer_id,
        customer_version: preview.customer_version,
        customer_external_id: preview.customer_external_id,
        customer_legal_name: preview.customer_legal_name,
        contract_id: preview.contract_id,
        billing_run_id: opts[:billing_run_id],
        currency: preview.currency,
        invoice_date: preview.invoice_date,
        usage_cutoff:
          Keyword.get_lazy(opts, :usage_cutoff, fn ->
            DateTime.new!(preview.invoice_date, ~T[00:00:00.000000], "Etc/UTC")
          end),
        lines: preview.lines,
        credit_application: credit_application(preview)
      })
    end
  end

  ## Rating

  defp rate_components(component_models, ctx) do
    Enum.reduce(component_models, {[], []}, fn {component, model}, {lines, blockers} ->
      case rate_component(component, model, ctx) do
        {:ok, line_or_lines} -> {lines ++ List.wrap(line_or_lines), blockers}
        :skip -> {lines, blockers}
        {:blocked, blocker} -> {lines, blockers ++ [blocker]}
      end
    end)
  end

  defp rate_component(component, model, ctx) do
    case model do
      %FixedRecurring{} ->
        rate_fixed(component, model, ctx)

      # A minimum commit over a non-metered inner rates like a fixed
      # recurring component (§10.6): the engine handles the max() uplift;
      # a metered inner routes through usage aggregation below.
      %BillingCore.Pricing.Model.MinimumCommit{inner: %FixedRecurring{}} ->
        rate_fixed(component, model, ctx)

      %OneTime{} ->
        # One-time components are billed through charge instances, not the
        # recurring preview (BC-US-041).
        :skip

      _metered ->
        rate_metered(component, model, ctx)
    end
  end

  defp rate_fixed(_component, _model, %{active_period: nil}), do: :skip

  defp rate_fixed(component, model, ctx) do
    {full_period, rated_active} =
      case component.proration_policy do
        :prorate -> {ctx.billing_period, ctx.active_period}
        :full_period -> {ctx.billing_period, ctx.billing_period}
      end

    request = %RatingRequest{
      pricing: model,
      currency: ctx.plan_version.currency,
      quantity: ctx.sub_version.quantity,
      full_period: full_period,
      active_period: rated_active
    }

    case Engine.rate(request) do
      {:ok, result} ->
        service_period = service_period(component, rated_active)
        product_name = Map.get(ctx.product_names, component.product_id, component.code)

        line_key =
          "subscription:#{ctx.subscription.external_id}:component:#{component.code}:" <>
            "#{ctx.billing_period.start_date}"

        description =
          Description.render(product_name,
            period: recognition_period(component, service_period),
            line_ref: String.slice(line_key, 0, 60)
          )

        {:ok,
         %{
           line_key: line_key,
           product_id: component.product_id,
           product_version: component.product_version,
           description: description,
           quantity: ctx.sub_version.quantity,
           amount_minor: result.amount.minor_units,
           recognition_mode: component.recognition_mode,
           service_start: service_start(component, service_period),
           service_end_exclusive: service_end(component, service_period),
           calculation_trace: result.trace,
           ordinal: component.ordinal
         }}

      {:error, reason} ->
        {:blocked, {:rating_failed, component.code, reason}}
    end
  end

  # Metered components aggregate frozen usage evidence for the billing period
  # (BC-US-053/055) and rate the resulting quantity — no proration.
  defp rate_metered(component, model, ctx) do
    aggregation = component.aggregation || :sum

    case BillingCore.Usage.aggregate(
           ctx.scope,
           ctx.subscription,
           component.metric_code,
           ctx.billing_period,
           ctx.usage_cutoff,
           aggregation: aggregation
         ) do
      {:ok, aggregate} ->
        request = %RatingRequest{
          pricing: model,
          currency: ctx.plan_version.currency,
          quantity: aggregate.quantity,
          full_period: ctx.billing_period,
          active_period: ctx.billing_period
        }

        case Engine.rate(request) do
          {:ok, result} ->
            line = metered_line(component, ctx, aggregate, result)

            case late_usage_adjustment(component, model, ctx) do
              {:ok, adjustment} -> {:ok, [line, adjustment]}
              :none -> {:ok, line}
            end

          {:error, reason} ->
            {:blocked, {:rating_failed, component.code, reason}}
        end

      {:error, reason} ->
        {:blocked, {:usage_aggregation_failed, component.code, reason}}
    end
  end

  # SPEC §18.5 carry_forward: usage for the previous period received after
  # that period's frozen cutoff is billed on this invoice as a separately
  # described prior-period adjustment. The prior cutoff comes from the frozen
  # snapshot of the invoice that billed the prior period; when the prior
  # period was never invoiced there is nothing to carry forward (the regular
  # rating path still covers it).
  defp late_usage_adjustment(component, model, ctx) do
    prior_period = prior_billing_period(ctx)

    base_key = fn suffix ->
      "subscription:#{ctx.subscription.external_id}:component:#{component.code}:#{suffix}"
    end

    with %Period{} <- prior_period,
         # The effective billed cutoff is the newest frozen cutoff covering
         # the prior period — via its regular line OR an earlier carry-forward
         # adjustment — so repeated previews/freezes never re-bill the same
         # late events.
         prior_cutoff when not is_nil(prior_cutoff) <-
           billed_cutoff_for(ctx, [
             base_key.(prior_period.start_date),
             base_key.("prior:#{prior_period.start_date}")
           ]),
         true <- DateTime.compare(ctx.usage_cutoff, prior_cutoff) == :gt do
      aggregation = component.aggregation || :sum

      {:ok, now_agg} =
        BillingCore.Usage.aggregate(
          ctx.scope,
          ctx.subscription,
          component.metric_code,
          prior_period,
          ctx.usage_cutoff,
          aggregation: aggregation
        )

      {:ok, then_agg} =
        BillingCore.Usage.aggregate(
          ctx.scope,
          ctx.subscription,
          component.metric_code,
          prior_period,
          prior_cutoff,
          aggregation: aggregation
        )

      if Decimal.eq?(now_agg.quantity, then_agg.quantity) do
        :none
      else
        marginal_adjustment(component, model, ctx, prior_period, now_agg, then_agg)
      end
    else
      _ -> :none
    end
  end

  # Marginal amount: rate(total now) − rate(total at the original cutoff), so
  # tier boundaries behave as if the late events had arrived on time.
  defp marginal_adjustment(component, model, ctx, prior_period, now_agg, then_agg) do
    currency = ctx.plan_version.currency

    with {:ok, now_result} <-
           Engine.rate(%RatingRequest{
             pricing: model,
             currency: currency,
             quantity: now_agg.quantity,
             full_period: prior_period,
             active_period: prior_period
           }),
         {:ok, then_result} <-
           Engine.rate(%RatingRequest{
             pricing: model,
             currency: currency,
             quantity: then_agg.quantity,
             full_period: prior_period,
             active_period: prior_period
           }) do
      delta_minor = now_result.amount.minor_units - then_result.amount.minor_units

      if delta_minor == 0 do
        :none
      else
        line_key =
          "subscription:#{ctx.subscription.external_id}:component:#{component.code}:" <>
            "prior:#{prior_period.start_date}"

        delta_quantity = Decimal.sub(now_agg.quantity, then_agg.quantity)

        description =
          Description.render(
            "Prior-period usage adjustment (#{component.metric_code})",
            period: recognition_period(component, prior_period),
            quantity: delta_quantity,
            unit: component.metric_code,
            rate: Decimal.new(0),
            currency: currency,
            line_ref: String.slice(line_key, 0, 60)
          )

        {:ok,
         %{
           line_key: line_key,
           product_id: component.product_id,
           product_version: component.product_version,
           description: description,
           quantity: delta_quantity,
           display_unit: component.metric_code,
           amount_minor: delta_minor,
           recognition_mode: component.recognition_mode,
           service_start: service_start(component, prior_period),
           service_end_exclusive: service_end(component, prior_period),
           calculation_trace: %{
             "kind" => "late_usage_carry_forward",
             "prior_period_start" => Date.to_iso8601(prior_period.start_date),
             "prior_cutoff_quantity" => Canonical.decimal_string(then_agg.quantity),
             "current_quantity" => Canonical.decimal_string(now_agg.quantity),
             "prior_amount_minor" => then_result.amount.minor_units,
             "current_amount_minor" => now_result.amount.minor_units
           },
           ordinal: component.ordinal + 1000
         }}
      end
    else
      _ -> :none
    end
  end

  defp prior_billing_period(ctx) do
    candidate_start = Date.add(ctx.billing_period.start_date, -1)

    if Date.before?(candidate_start, ctx.subscription.start_date) do
      nil
    else
      billing_period(ctx.subscription, ctx.plan_version, candidate_start)
    end
  end

  # The newest usage cutoff that billed any of `line_keys`, from the owning
  # intents' frozen snapshots; nil when the prior period has no active invoice.
  defp billed_cutoff_for(ctx, line_keys) do
    team_id = Scope.team_id!(ctx.scope)

    Repo.all(
      from l in BillingCore.Billing.InvoiceLine,
        join: i in BillingCore.Billing.InvoiceIntent,
        on: i.id == l.invoice_intent_id,
        join: lc in "invoice_intent_lifecycle",
        prefix: "billing",
        on: lc.invoice_intent_id == i.id,
        where: l.team_id == ^team_id and l.line_key in ^line_keys,
        where: lc.current_state != "superseded",
        select: fragment("? ->> 'usageCutoff'", i.canonical_snapshot)
    )
    |> Enum.flat_map(fn cutoff ->
      case is_binary(cutoff) && DateTime.from_iso8601(cutoff) do
        {:ok, dt, _} -> [dt]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      cutoffs -> Enum.max(cutoffs, DateTime)
    end
  end

  defp metered_line(component, ctx, aggregate, result) do
    service_period = service_period(component, ctx.billing_period)
    product_name = Map.get(ctx.product_names, component.product_id, component.code)

    line_key =
      "subscription:#{ctx.subscription.external_id}:component:#{component.code}:" <>
        "#{ctx.billing_period.start_date}"

    description =
      Description.render(product_name,
        period: recognition_period(component, service_period),
        quantity: aggregate.quantity,
        unit: component.metric_code,
        rate: effective_rate(aggregate.quantity, result),
        currency: ctx.plan_version.currency,
        line_ref: String.slice(line_key, 0, 60)
      )

    trace =
      Map.merge(result.trace, %{
        "usage" => %{
          "metric_code" => component.metric_code,
          "aggregation" => to_string(aggregate.aggregation),
          "event_count" => aggregate.event_count,
          "excluded_late" => aggregate.excluded_late,
          "cutoff" => DateTime.to_iso8601(aggregate.cutoff)
        }
      })

    %{
      line_key: line_key,
      product_id: component.product_id,
      product_version: component.product_version,
      description: description,
      quantity: aggregate.quantity,
      display_unit: component.metric_code,
      amount_minor: result.amount.minor_units,
      recognition_mode: component.recognition_mode,
      service_start: service_start(component, service_period),
      service_end_exclusive: service_end(component, service_period),
      calculation_trace: trace,
      ordinal: component.ordinal
    }
  end

  # Effective per-unit rate for the §17.6 description line.
  defp effective_rate(quantity, result) do
    if Decimal.eq?(quantity, 0) do
      Decimal.new(0)
    else
      result.amount
      |> Money.to_major_decimal()
      |> Decimal.div(quantity)
      |> Decimal.round(6)
    end
  end

  defp service_period(_component, active_period), do: active_period

  defp recognition_period(%{recognition_mode: :over_time}, period), do: period
  defp recognition_period(_, _), do: nil

  defp service_start(%{recognition_mode: :over_time}, %Period{start_date: d}), do: d
  defp service_start(_, _), do: nil

  defp service_end(%{recognition_mode: :over_time}, %Period{end_date_exclusive: d}), do: d
  defp service_end(_, _), do: nil

  ## Discounts

  defp discount_structs(scope, subscription, contract) do
    {:ok, assignments} =
      Catalog.list_discount_assignments(scope,
        subscription_id: subscription.id,
        contract_id: contract.id
      )

    assignments
    |> Enum.filter(&(&1.status == :active))
    |> Enum.map(&load_discount_struct/1)
    |> Enum.reject(&is_nil/1)
  end

  defp load_discount_struct(assignment) do
    version =
      Repo.one(
        from v in "discount_versions",
          prefix: "billing",
          where: v.id == type(^assignment.discount_version_id, Ecto.UUID),
          select: %{
            id: v.id,
            discount_type: v.discount_type,
            basis_points: v.basis_points,
            amount_minor: v.amount_minor,
            currency: v.currency,
            priority: v.priority
          }
      )

    case version do
      %{discount_type: "percentage"} = v ->
        %BillingCore.Pricing.PercentageDiscount{
          id: Ecto.UUID.cast!(v.id),
          basis_points: v.basis_points,
          priority: v.priority
        }

      %{discount_type: "fixed_amount"} = v ->
        %BillingCore.Pricing.FixedDiscount{
          id: Ecto.UUID.cast!(v.id),
          amount_minor: v.amount_minor,
          currency: v.currency,
          priority: v.priority
        }

      nil ->
        nil
    end
  end

  defp apply_discounts(charge_lines, [], currency) do
    net =
      charge_lines
      |> Enum.map(&Money.new!(currency, &1.amount_minor))
      |> Money.sum!(currency)

    {charge_lines, net.minor_units}
  end

  defp apply_discounts(charge_lines, discounts, currency) do
    eligible =
      Enum.map(charge_lines, fn line ->
        %EligibleLine{
          id: line.line_key,
          amount: Money.new!(currency, line.amount_minor),
          service_period: eligible_period(line),
          recognition_mode: line.recognition_mode
        }
      end)

    result = Discounts.apply_discounts(eligible, discounts)
    by_key = Map.new(charge_lines, &{&1.line_key, &1})
    next_ordinal = charge_lines |> Enum.map(& &1.ordinal) |> Enum.max(fn -> -1 end) |> Kernel.+(1)

    discount_lines =
      result.discount_lines
      |> Enum.with_index(next_ordinal)
      |> Enum.map(fn {dline, ordinal} ->
        source = Map.fetch!(by_key, dline.source_line_id)

        %{
          line_key: "discount:#{dline.discount_id}:#{dline.source_line_id}",
          product_id: source.product_id,
          product_version: source.product_version,
          description:
            Description.render("contract discount",
              period: eligible_period(source),
              kind: :discount,
              line_ref: String.slice("d:#{dline.source_line_id}", 0, 60)
            ),
          quantity: Decimal.new(1),
          amount_minor: dline.allocation.minor_units,
          recognition_mode: source.recognition_mode,
          service_start: source.service_start,
          service_end_exclusive: source.service_end_exclusive,
          calculation_trace: dline.trace || %{},
          adjusts_line_id: nil,
          ordinal: ordinal
        }
      end)

    lines = charge_lines ++ discount_lines

    net =
      lines
      |> Enum.map(&Money.new!(currency, &1.amount_minor))
      |> Money.sum!(currency)

    {lines, net.minor_units}
  end

  defp eligible_period(%{service_start: nil}), do: nil
  defp eligible_period(line), do: Period.new!(line.service_start, line.service_end_exclusive)

  defp credit_application(%__MODULE__{credit_planned_minor: planned} = preview)
       when planned > 0 do
    %{credit_account: preview.credit_account, amount_minor: planned}
  end

  defp credit_application(_preview), do: nil

  # Customer credit eligible to offset this invoice (BC-US-108): the
  # customer's commercial account may hold a currency-scoped credit balance.
  # SPEC §9.4.1: a certified receivable-settlement mode is a precondition
  # for automatic application — with none, no credit is planned (the system
  # never nets an invoice silently).
  defp credit_availability(scope, customer, currency) do
    team_id = Scope.team_id!(scope)

    {settlement_mode, _policy} = BillingCore.Credits.Settlements.settlement_mode(team_id)

    if settlement_mode == :none do
      {nil, 0}
    else
      credit_account_balance(team_id, customer, currency)
    end
  end

  defp credit_account_balance(team_id, customer, currency) do
    account_id =
      Repo.one(
        from atc in "account_team_customers",
          prefix: "billing",
          where:
            atc.team_id == type(^team_id, Ecto.UUID) and
              atc.customer_id == type(^customer.id, Ecto.UUID),
          select: atc.account_id,
          limit: 1
      )

    case account_id do
      nil ->
        {nil, 0}

      account_id ->
        account =
          Repo.one(
            from a in BillingCore.Credits.CreditAccount,
              where:
                a.team_id == ^team_id and
                  a.account_id == type(^account_id, Ecto.UUID) and
                  a.currency == ^currency
          )

        case account do
          nil -> {nil, 0}
          account -> {account, account.available_minor}
        end
    end
  end

  ## Period resolution

  defp billing_period(subscription, plan_version, as_of) do
    case plan_version.interval_unit do
      :month ->
        Period.billing_period_at(subscription.start_date, as_of, plan_version.interval_count)

      :day ->
        days_since = Date.diff(as_of, subscription.start_date)
        n = div(max(days_since, 0), plan_version.interval_count)
        start = Date.add(subscription.start_date, n * plan_version.interval_count)
        Period.new!(start, Date.add(start, plan_version.interval_count))
    end
  end

  # Intersection of the billing period with the subscription's active window
  # `[start_date, end_date_exclusive | ∞)`; `nil` when no service falls in the
  # period (e.g. already-ended subscription).
  defp active_period(subscription, billing_period) do
    window_end = subscription.end_date_exclusive || billing_period.end_date_exclusive

    case Period.new(subscription.start_date, window_end) do
      {:ok, window} -> Period.intersect(billing_period, window)
      {:error, :invalid_period} -> nil
    end
  end

  ## Metadata

  defp product_names(scope, component_models) do
    ids = component_models |> Enum.map(fn {c, _} -> c.product_id end) |> Enum.uniq()
    team_id = Scope.team_id!(scope)

    Repo.all(
      from p in "products",
        prefix: "billing",
        where: p.team_id == type(^team_id, Ecto.UUID) and p.id in type(^ids, {:array, Ecto.UUID}),
        select: {p.id, p.name}
    )
    |> Map.new(fn {id, name} -> {Ecto.UUID.cast!(id), name} end)
  end

  defp customer_legal_name(customer) do
    version =
      Repo.one(
        from v in "customer_versions",
          prefix: "billing",
          where:
            v.customer_id == type(^customer.id, Ecto.UUID) and
              v.version == ^customer.current_version,
          select: v.legal_name
      )

    version || customer.external_id
  end

  defp current_subscription_version(scope, subscription, as_of) do
    {:ok, versions} = Contracts.list_subscription_versions(scope, subscription)

    current =
      Enum.find(versions, fn v ->
        not Date.before?(as_of, v.effective_start) and
          (is_nil(v.effective_end_exclusive) or Date.before?(as_of, v.effective_end_exclusive))
      end)

    case current do
      nil -> {:error, :no_effective_subscription_version}
      version -> {:ok, version}
    end
  end

  defp fingerprint(%__MODULE__{} = preview) do
    Canonical.hash(%{
      "subscriptionId" => preview.subscription_id,
      "customerId" => preview.customer_id,
      "customerVersion" => preview.customer_version,
      "currency" => preview.currency,
      "invoiceDate" => preview.invoice_date,
      "lines" =>
        Enum.map(preview.lines, fn line ->
          %{
            "lineKey" => line.line_key,
            "amountMinor" => line.amount_minor,
            "quantity" => line.quantity,
            "recognitionMode" => to_string(line.recognition_mode)
          }
        end),
      "netAmountMinor" => preview.net_amount_minor,
      "blockers" => Enum.map(preview.blockers, &inspect/1)
    })
  end
end
