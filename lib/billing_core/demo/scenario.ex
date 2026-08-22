defmodule BillingCore.Demo.Scenario do
  @moduledoc """
  Deterministic "Northstar" guided scenario for the demo workspace
  (BC-US-166, SPEC §34).

  The scenario executes only ordinary scoped context commands — the same
  Catalog/Contracts/Billing/ERP commands every real team uses — and derives
  journey progress exclusively from durable domain rows. Artifact references
  recorded through `BillingCore.Demo.mark_step/3` are evidence pointers for
  the guided page; they are never the source of completion truth.

  Determinism: every artifact uses a fixed code inside the workspace's fresh
  team, and all dates anchor on the first day of the month the workspace was
  provisioned (`anchor_date/1`, durable via `started_at`). Re-running any
  step after an interruption converges on the same artifacts.
  """

  alias BillingCore.{Billing, Catalog, Contracts, Credits, Demo, ERP, Orgs, Repo}
  alias BillingCore.Credits.CloseWorkflow
  alias BillingCore.Demo.Workspace
  alias BillingCore.Orgs.Account

  @product_code "northstar-platform"
  @product_name "Northstar Platform"
  @plan_code "northstar-annual"
  @plan_name "Northstar Annual Prepaid"
  @component_code "annual-platform"
  @annual_amount "120000.00"
  @customer_external_id "northstar-fjordlys"
  @customer_legal_name "Fjordlys Analytics ApS"
  @contract_reference "northstar-agreement"
  @subscription_external_id "northstar-subscription"
  @erp_customer_number "1001"
  @erp_product_number "NS-PLATFORM"
  @account_external_id "northstar-account"
  @account_display_name "Fjordlys Analytics"
  @credit_origin "goodwill"
  @credit_amount_minor 250_000
  @credit_idempotency_key "northstar-goodwill-1"

  @commercial_step "commercial_model"
  @invoice_step "first_invoice"
  @credit_step "customer_credit"
  @close_step "aggregate_close"

  @type phase :: %{state: atom(), refs: map()}
  @type journey :: %{
          commercial: phase(),
          invoice: phase(),
          credit: phase(),
          close: phase(),
          anchor_date: Date.t()
        }

  @doc "The deterministic date all scenario artifacts anchor on."
  @spec anchor_date(Workspace.t()) :: Date.t()
  def anchor_date(%Workspace{started_at: %DateTime{} = started_at}) do
    started_at |> DateTime.to_date() |> Date.beginning_of_month()
  end

  @doc """
  Derives the guided journey state exclusively from durable domain rows.
  Performs reads only; never consults `workspace.progress`.
  """
  @spec status(Demo.bundle()) :: journey()
  def status(%{scope: scope, workspace: workspace, connection: connection}) do
    commercial = commercial_phase(scope, connection)
    invoice = invoice_phase(scope, commercial)
    credit = credit_phase(scope, commercial, invoice)

    %{
      commercial: commercial,
      invoice: invoice,
      credit: credit,
      close: close_phase(scope, credit),
      anchor_date: anchor_date(workspace)
    }
  end

  @doc """
  Derives the journey and records durable completions on the workspace as
  artifact references (`Demo.mark_step/3`) when they are not recorded yet.
  """
  @spec observe(Demo.bundle()) :: {:ok, journey()}
  def observe(%{scope: scope, workspace: workspace} = bundle) do
    journey = status(bundle)

    if journey.commercial.state == :complete do
      record_if_new(scope, workspace, @commercial_step, journey.commercial.refs)
    end

    if journey.invoice.state == :erp_booked do
      record_if_new(scope, workspace, @invoice_step, journey.invoice.refs)
    end

    if journey.credit.state == :complete do
      record_if_new(scope, workspace, @credit_step, journey.credit.refs)
    end

    if journey.close.state == :closed do
      record_if_new(scope, workspace, @close_step, journey.close.refs)
    end

    {:ok, journey}
  end

  @doc """
  Creates the missing pieces of the Northstar commercial model through
  ordinary context commands, atomically and idempotently: product, annual
  prepaid plan version, customer, ERP mappings, contract, and subscription.
  Safe to re-run after any interruption; existing artifacts are reused.
  """
  @spec build_commercial_model(Demo.bundle()) :: {:ok, map()} | {:error, term()}
  def build_commercial_model(%{scope: scope, workspace: workspace, connection: connection}) do
    anchor = anchor_date(workspace)

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "demo-scenario:#{workspace.id}"
        ])

        case ensure_commercial(scope, connection, anchor) do
          {:ok, refs} -> refs
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, refs} <- result do
      record_if_new(scope, workspace, @commercial_step, refs)
      {:ok, refs}
    end
  end

  @doc """
  Records the deterministic Northstar goodwill credit through the ordinary
  account/projection/credit commands, atomically and idempotently. Refuses
  while the invoice phase has not reached a booked, reconciled document —
  the guided story records the liability only after the commercial proof.
  """
  @spec record_customer_credit(Demo.bundle()) :: {:ok, map()} | {:error, term()}
  def record_customer_credit(
        %{scope: scope, workspace: workspace, organization: organization, team: team} = bundle
      ) do
    journey = status(bundle)

    with :ok <- ensure_credit_unlocked(journey) do
      customer_id = journey.commercial.refs["customer_id"]

      result =
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
            "demo-scenario:#{workspace.id}"
          ])

          case ensure_credit(scope, organization, team, customer_id) do
            {:ok, refs} -> refs
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      with {:ok, refs} <- result do
        record_if_new(scope, workspace, @credit_step, refs)
        {:ok, refs}
      end
    end
  end

  defp ensure_credit_unlocked(%{credit: %{state: :locked}}), do: {:error, :locked}
  defp ensure_credit_unlocked(_journey), do: :ok

  defp ensure_credit(scope, organization, team, customer_id) do
    with {:ok, account} <- ensure_org_account(scope, organization),
         {:ok, _projection} <- Orgs.project_account_to_team(account, team, customer_id, scope),
         {:ok, credit_account} <- Credits.get_or_create_account(scope, account.id, "DKK"),
         {:ok, grant} <-
           Credits.grant_credit(scope, %{
             credit_account_id: credit_account.id,
             origin_type: @credit_origin,
             amount_minor: @credit_amount_minor,
             currency: "DKK",
             idempotency_key: @credit_idempotency_key,
             reason_code: "demo_goodwill",
             metadata: %{"note" => "Service-level goodwill agreed with Fjordlys Analytics"}
           }) do
      {:ok, credit_refs(credit_account, grant)}
    end
  end

  # The organization account has no scoped read API by external ID; this
  # read-only lookup keeps the build convergent if a prior attempt created
  # the account without completing the projection.
  defp ensure_org_account(scope, organization) do
    case Repo.get_by(Account, organization_id: organization.id, external_id: @account_external_id) do
      nil ->
        Orgs.create_account(
          organization,
          %{external_id: @account_external_id, display_name: @account_display_name},
          scope
        )

      account ->
        {:ok, account}
    end
  end

  ## Credit phase derivation

  defp credit_phase(_scope, commercial, invoice)
       when commercial.state != :complete
       when invoice.state != :erp_booked,
       do: %{state: :locked, refs: %{}}

  defp credit_phase(scope, %{refs: %{"customer_id" => customer_id}}, _invoice) do
    {:ok, accounts} = Credits.list_accounts_for_customer(scope, customer_id)

    with %{} = credit_account <- Enum.find(accounts, &(&1.currency == "DKK")),
         {:ok, grants} <- Credits.list_grants(scope, credit_account),
         %{} = grant <- Enum.find(grants, &(&1.origin_type == @credit_origin)) do
      %{state: :complete, refs: credit_refs(credit_account, grant)}
    else
      _missing -> %{state: :not_started, refs: %{}}
    end
  end

  defp credit_refs(credit_account, grant) do
    %{
      "credit_account_id" => credit_account.id,
      "account_id" => credit_account.account_id,
      "grant_id" => grant.id,
      "origin_type" => grant.origin_type,
      "granted_minor" => grant.granted_minor,
      "currency" => grant.currency,
      "granted_at" => DateTime.to_iso8601(grant.granted_at)
    }
  end

  ## Aggregate-close phase derivation

  # The close is guided entirely through the real credit-closes surface;
  # this phase only derives sub-state from the durable close rows.
  defp close_phase(_scope, %{state: state}) when state != :complete,
    do: %{state: :locked, refs: %{}}

  defp close_phase(scope, _credit) do
    {:ok, closes} = CloseWorkflow.list_closes(scope, limit: 1)

    case closes do
      [] -> %{state: :not_started, refs: %{}}
      [close | _rest] -> %{state: close_state(close.state), refs: close_refs(scope, close)}
    end
  end

  defp close_state(:open), do: :generating
  defp close_state(:calculating), do: :generating
  defp close_state(:failed), do: :generation_failed
  defp close_state(:ready), do: :ready
  defp close_state(:approved), do: :approved
  defp close_state(:posting), do: :posting
  defp close_state(:outcome_unknown), do: :posting
  defp close_state(:posted), do: :posting
  defp close_state(:mismatch), do: :mismatch
  defp close_state(:reconciled), do: :reconciled
  defp close_state(:closed), do: :closed
  defp close_state(_other), do: :not_started

  defp close_refs(scope, close) do
    base =
      %{
        "close_id" => close.id,
        "currency" => close.currency,
        "period_start" => Date.to_iso8601(close.period_start),
        "period_end_exclusive" => Date.to_iso8601(close.period_end_exclusive)
      }
      |> put_if("opening_minor", close.opening_minor)
      |> put_if("net_change_minor", close.net_change_minor)
      |> put_if("closing_minor", close.closing_minor)
      |> put_if("report_sha256", close.report_sha256)
      |> put_if("closed_at", close.closed_at && DateTime.to_iso8601(close.closed_at))

    case CloseWorkflow.posting_status(scope, close) do
      {:ok, %{document: %{external_voucher_number: number}}} when is_binary(number) ->
        Map.put(base, "external_voucher_number", number)

      _other ->
        base
    end
  end

  ## Commercial phase derivation

  defp commercial_phase(scope, connection) do
    artifacts = commercial_artifacts(scope, connection)
    present = artifacts |> Map.values() |> Enum.reject(&is_nil/1)

    cond do
      Enum.count(present) == map_size(artifacts) ->
        %{state: :complete, refs: commercial_refs(artifacts)}

      present == [] ->
        %{state: :not_started, refs: %{}}

      true ->
        %{state: :partial, refs: %{}}
    end
  end

  defp commercial_artifacts(scope, connection) do
    product = find_product(scope)
    plan = find_plan(scope)
    plan_version = plan && published_plan_version(scope, plan)
    component = plan_version && find_component(scope, plan_version)
    customer = find_customer(scope)
    contract = customer && find_contract(scope, customer)
    subscription = find_subscription(scope)

    %{
      product: product,
      plan: plan,
      plan_version: plan_version,
      component: component,
      customer: customer,
      customer_mapping: customer && find_customer_mapping(scope, customer, connection),
      product_mapping: product && find_product_mapping(scope, product, connection),
      contract: contract,
      subscription: subscription
    }
  end

  defp commercial_refs(artifacts) do
    %{
      "product_id" => artifacts.product.id,
      "plan_id" => artifacts.plan.id,
      "plan_version_id" => artifacts.plan_version.id,
      "price_component_id" => artifacts.component.id,
      "customer_id" => artifacts.customer.id,
      "contract_id" => artifacts.contract.id,
      "subscription_id" => artifacts.subscription.id,
      "erp_customer_number" => @erp_customer_number,
      "erp_product_number" => @erp_product_number
    }
  end

  ## Invoice phase derivation

  defp invoice_phase(_scope, %{state: state}) when state != :complete,
    do: %{state: :locked, refs: %{}}

  defp invoice_phase(scope, %{refs: %{"customer_id" => customer_id}}) do
    {:ok, rows} = Billing.list_intents(scope, customer_id: customer_id)

    case Enum.find(rows, fn %{state: state} -> state != "superseded" end) do
      nil ->
        %{state: :not_started, refs: %{}}

      %{intent: intent, state: state} ->
        document = ERP.get_document_for_intent(scope, intent.id)
        %{state: invoice_state(state), refs: invoice_refs(intent, document)}
    end
  end

  # `credit_required` is a post-booking correction state: the document itself
  # remains booked, which is what this phase reports on.
  defp invoice_state("credit_required"), do: :erp_booked
  defp invoice_state(state), do: String.to_existing_atom(state)

  defp invoice_refs(intent, document) do
    base = %{
      "invoice_intent_id" => intent.id,
      "invoice_chain_id" => intent.invoice_chain_id,
      "content_hash" => intent.content_hash,
      "net_amount_minor" => intent.net_amount_minor,
      "currency" => intent.currency
    }

    case document do
      nil ->
        base

      document ->
        base
        |> Map.put("erp_document_id", document.id)
        |> put_if("external_draft_number", document.external_draft_number)
        |> put_if("external_booked_number", document.external_booked_number)
        |> put_if(
          "reconciled_at",
          document.last_reconciled_at && DateTime.to_iso8601(document.last_reconciled_at)
        )
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  ## Idempotent commercial build

  defp ensure_commercial(scope, connection, anchor) do
    with {:ok, product} <- ensure_product(scope),
         {:ok, plan} <- ensure_plan(scope),
         {:ok, plan_version, component} <- ensure_published_version(scope, plan, product),
         {:ok, customer} <- ensure_customer(scope),
         {:ok, _customer_mapping} <-
           Contracts.upsert_customer_erp_mapping(scope, customer, %{
             erp_connection_id: connection.id,
             external_customer_number: @erp_customer_number
           }),
         {:ok, _product_mapping} <-
           Catalog.upsert_product_erp_mapping(scope, product, %{
             erp_connection_id: connection.id,
             external_product_number: @erp_product_number
           }),
         {:ok, contract} <- ensure_contract(scope, customer, anchor),
         {:ok, subscription} <- ensure_subscription(scope, contract, plan_version, anchor) do
      {:ok,
       commercial_refs(%{
         product: product,
         plan: plan,
         plan_version: plan_version,
         component: component,
         customer: customer,
         contract: contract,
         subscription: subscription
       })}
    end
  end

  defp ensure_product(scope) do
    case find_product(scope) do
      nil ->
        Catalog.create_product(scope, %{
          code: @product_code,
          name: @product_name,
          description:
            "Annual platform access, billed in advance and recognized over the service year.",
          recognition_mode: :over_time,
          service_period_source: :billing_period
        })

      product ->
        {:ok, product}
    end
  end

  defp ensure_plan(scope) do
    case find_plan(scope) do
      nil -> Catalog.create_plan(scope, %{code: @plan_code, name: @plan_name})
      plan -> {:ok, plan}
    end
  end

  defp ensure_published_version(scope, plan, product) do
    case published_plan_version(scope, plan) do
      nil ->
        with {:ok, draft} <- ensure_draft_version(scope, plan),
             {:ok, component} <- ensure_component(scope, draft, product),
             {:ok, published} <- Catalog.publish_plan_version(scope, draft) do
          {:ok, published, component}
        end

      published ->
        case find_component(scope, published) do
          nil -> {:error, :demo_component_missing}
          component -> {:ok, published, component}
        end
    end
  end

  defp ensure_draft_version(scope, plan) do
    {:ok, versions} = Catalog.list_plan_versions(scope, plan)

    case Enum.find(versions, &(&1.status == :draft)) do
      nil ->
        Catalog.create_draft_plan_version(scope, plan, %{
          currency: "DKK",
          interval_unit: :month,
          interval_count: 12,
          billing_timing: :in_advance
        })

      draft ->
        {:ok, draft}
    end
  end

  defp ensure_component(scope, draft, product) do
    case find_component(scope, draft) do
      nil ->
        Catalog.add_price_component(scope, draft, %{
          code: @component_code,
          product_id: product.id,
          pricing_definition: %{
            "schema_version" => 1,
            "type" => "fixed_recurring",
            "unit_price" => @annual_amount
          }
        })

      component ->
        {:ok, component}
    end
  end

  defp ensure_customer(scope) do
    case find_customer(scope) do
      nil ->
        with {:ok, %{customer: customer}} <-
               Contracts.upsert_customer(scope, %{
                 external_id: @customer_external_id,
                 legal_name: @customer_legal_name,
                 address_line: "Åboulevarden 22",
                 zip: "8000",
                 city: "Aarhus C",
                 country: "DK",
                 email: "regnskab@fjordlys.example",
                 vat_number: "DK76543210",
                 currency_preference: "DKK"
               }) do
          {:ok, customer}
        end

      customer ->
        {:ok, customer}
    end
  end

  defp ensure_contract(scope, customer, anchor) do
    case find_contract(scope, customer) do
      nil ->
        Contracts.create_contract(scope, %{
          customer_id: customer.id,
          external_reference: @contract_reference,
          currency: "DKK",
          start_date: anchor
        })

      contract ->
        {:ok, contract}
    end
  end

  defp ensure_subscription(scope, contract, plan_version, anchor) do
    case find_subscription(scope) do
      nil ->
        Contracts.start_subscription(scope, %{
          external_id: @subscription_external_id,
          contract_id: contract.id,
          plan_version_id: plan_version.id,
          start_date: anchor,
          quantity: Decimal.new(1)
        })

      subscription ->
        {:ok, subscription}
    end
  end

  ## Durable-row lookups (ordinary read APIs only)

  defp find_product(scope) do
    {:ok, products} = Catalog.list_products(scope)
    Enum.find(products, &(&1.code == @product_code))
  end

  defp find_plan(scope) do
    {:ok, plans} = Catalog.list_plans(scope)
    Enum.find(plans, &(&1.code == @plan_code))
  end

  defp published_plan_version(scope, plan) do
    {:ok, versions} = Catalog.list_plan_versions(scope, plan)

    versions
    |> Enum.filter(&(&1.status == :published))
    |> Enum.max_by(& &1.version, fn -> nil end)
  end

  defp find_component(scope, plan_version) do
    {:ok, components} = Catalog.list_price_components(scope, plan_version)
    Enum.find(components, &(&1.code == @component_code))
  end

  defp find_customer(scope) do
    {:ok, customers} = Contracts.list_customers(scope)
    Enum.find(customers, &(&1.external_id == @customer_external_id))
  end

  defp find_customer_mapping(scope, customer, connection) do
    {:ok, mappings} = Contracts.list_customer_erp_mappings(scope, customer)
    Enum.find(mappings, &(&1.erp_connection_id == connection.id))
  end

  defp find_product_mapping(scope, product, connection) do
    {:ok, mappings} = Catalog.list_product_erp_mappings(scope, product)
    Enum.find(mappings, &(&1.erp_connection_id == connection.id))
  end

  defp find_contract(scope, customer) do
    {:ok, contracts} = Contracts.list_contracts(scope, customer_id: customer.id)
    Enum.find(contracts, &(&1.external_reference == @contract_reference))
  end

  defp find_subscription(scope) do
    case Contracts.get_subscription_by_external_id(scope, @subscription_external_id) do
      {:ok, subscription} -> subscription
      {:error, :not_found} -> nil
    end
  end

  defp record_if_new(scope, workspace, step, refs) do
    # The caller's bundle may predate an earlier mark in the same pass;
    # decide from the durable row, not the snapshot.
    workspace = Repo.get(Workspace, workspace.id) || workspace
    progress = workspace.progress || %{}
    first_completion? = not Map.has_key?(progress, step)

    if Map.get(progress, step) != refs do
      case Demo.mark_step(scope, step, refs) do
        {:ok, _workspace} ->
          if first_completion?, do: emit_activation_telemetry(workspace, step)
          :ok

        {:error, _reason} ->
          :ok
      end
    end

    :ok
  end

  # BC-US-166 activation evidence: how long a fresh workspace took to reach
  # each journey proof, most importantly the first reconciled invoice and
  # the first accepted customer-credit close.
  defp emit_activation_telemetry(workspace, step) do
    :telemetry.execute(
      [:billing_core, :demo, :step_completed],
      %{seconds_since_start: DateTime.diff(DateTime.utc_now(), workspace.started_at)},
      %{
        step: step,
        scenario_version: workspace.scenario_version,
        generation: workspace.generation
      }
    )
  end
end
