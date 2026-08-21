defmodule BillingCoreWeb.GraphQL.Resolvers.Billing do
  @moduledoc """
  Billing runs, invoice preview, and invoice intent resolvers
  (SPEC §14.5 billing capability group, BC-US-068/069/100).
  """

  import Ecto.Query

  alias BillingCore.{Billing, Idempotency, Repo, Scope}
  alias BillingCore.Billing.{BillingRun, InvoiceIntent, InvoiceLine, Preview}
  alias BillingCoreWeb.GraphQL.{Authz, Errors}
  alias BillingCoreWeb.GraphQL.Resolvers.Contracts, as: Shared

  ## Queries

  def billing_run(_parent, %{id: id}, %{context: %{scope: scope}}) do
    with true <- Authz.can_read?(scope),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         %BillingRun{} = run <- Repo.get_by(BillingRun, id: uuid, team_id: Scope.team_id!(scope)) do
      {:ok, run}
    else
      false -> Errors.unauthorized()
      _ -> Errors.not_found()
    end
  end

  def invoice_intent(_parent, %{id: id}, %{context: %{scope: scope}}) do
    with true <- Authz.can_read?(scope),
         {:ok, intent} <- Billing.get_intent(scope, id) do
      {:ok, intent}
    else
      false -> Errors.unauthorized()
      {:error, :not_found} -> Errors.not_found()
    end
  end

  def intent_state(intent, _args, _resolution) do
    {:ok, Billing.intent_state(intent)}
  end

  def intent_lines(%InvoiceIntent{} = intent, _args, _resolution) do
    case intent.lines do
      %Ecto.Association.NotLoaded{} ->
        {:ok,
         Repo.all(
           from l in InvoiceLine,
             where: l.invoice_intent_id == ^intent.id and l.team_id == ^intent.team_id,
             order_by: [asc: l.ordinal]
         )}

      lines when is_list(lines) ->
        {:ok, Enum.sort_by(lines, & &1.ordinal)}
    end
  end

  def invoice_preview(_parent, args, %{context: %{scope: scope}}) do
    case Preview.for_subscription(scope, args.subscription_id, args.as_of) do
      {:ok, preview} -> {:ok, present_preview(preview)}
      {:error, :unauthorized} -> Errors.unauthorized()
      {:error, :not_found} -> Errors.not_found()
      {:error, reason} -> Errors.query_error(preview_error_code(reason), "preview unavailable")
    end
  end

  ## createBillingRun

  def create_billing_run(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    attrs = %{
      run_key: input.run_key,
      invoice_date: input.invoice_date,
      usage_cutoff: input.usage_cutoff
    }

    outcome =
      Idempotency.run(
        Scope.team_id!(scope),
        "create_billing_run",
        input.idempotency_key,
        Authz.principal_id(scope),
        Shared.canonical_input(input),
        fn ->
          case Billing.open_run(scope, attrs) do
            {:ok, run} -> {:ok, %{"resource_reference" => run.id}}
            {:error, reason} -> {:error, reason}
          end
        end
      )

    case Shared.resolve_outcome(outcome, scope, &fetch_billing_run/2) do
      {:ok, run} -> {:ok, %{billing_run: run, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## freezeInvoiceIntent

  def freeze_invoice_intent(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    outcome =
      Idempotency.run(
        Scope.team_id!(scope),
        "freeze_invoice_intent",
        input.idempotency_key,
        Authz.principal_id(scope),
        Shared.canonical_input(input),
        fn ->
          with {:ok, preview} <-
                 Preview.for_subscription(scope, input.subscription_id, input.as_of),
               {:ok, intent} <-
                 Preview.freeze(scope, preview, billing_run_id: input[:billing_run_id]) do
            {:ok, %{"resource_reference" => intent.id}}
          end
        end
      )

    case Shared.resolve_outcome(outcome, scope, &Billing.get_intent/2) do
      {:ok, intent} -> {:ok, %{invoice_intent: intent, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## supersedeInvoiceIntent

  def supersede_invoice_intent(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:intent, {:ok, old_intent}} <-
           {:intent, Billing.get_intent(scope, input.invoice_intent_id)},
         {:preview, {:ok, preview}} <-
           {:preview, Preview.for_subscription(scope, input.subscription_id, input.as_of)},
         {:blockers, []} <- {:blockers, preview.blockers},
         {:supersede, {:ok, replacement}} <-
           {:supersede,
            Billing.supersede_invoice_intent(scope, old_intent, %{
              customer_id: preview.customer_id,
              customer_version: preview.customer_version,
              customer_external_id: preview.customer_external_id,
              customer_legal_name: preview.customer_legal_name,
              contract_id: preview.contract_id,
              currency: preview.currency,
              invoice_date: preview.invoice_date,
              usage_cutoff: DateTime.new!(preview.invoice_date, ~T[00:00:00], "Etc/UTC"),
              lines: preview.lines,
              reason: input[:reason]
            })} do
      {:ok, %{invoice_intent: replacement, client_mutation_id: cmid}}
    else
      {:intent, {:error, reason}} -> {:ok, Errors.business_error(reason, cmid)}
      {:preview, {:error, reason}} -> {:ok, Errors.business_error(reason, cmid)}
      {:blockers, blockers} -> {:ok, Errors.business_error({:blocked, blockers}, cmid)}
      {:supersede, {:error, reason}} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## Internals

  defp fetch_billing_run(scope, id) do
    case Repo.get_by(BillingRun, id: id, team_id: Scope.team_id!(scope)) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  defp present_preview(%Preview{} = preview) do
    %{
      subscription_id: preview.subscription_id,
      customer_id: preview.customer_id,
      contract_id: preview.contract_id,
      currency: preview.currency,
      invoice_date: preview.invoice_date,
      period_start: preview.billing_period.start_date,
      period_end_exclusive: preview.billing_period.end_date_exclusive,
      net_amount_minor: preview.net_amount_minor,
      fingerprint: preview.fingerprint,
      blockers: Enum.map(preview.blockers, &Errors.blocker_string/1),
      lines:
        Enum.map(preview.lines, fn line ->
          %{
            line_key: line.line_key,
            description: line.description,
            quantity: line.quantity,
            amount_minor: line.amount_minor,
            recognition_mode: to_string(line.recognition_mode),
            service_start: line.service_start,
            service_end_exclusive: line.service_end_exclusive,
            ordinal: line.ordinal,
            product_id: line.product_id
          }
        end)
    }
  end

  defp preview_error_code(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.upcase()

  defp preview_error_code(_reason), do: "PREVIEW_FAILED"
end
