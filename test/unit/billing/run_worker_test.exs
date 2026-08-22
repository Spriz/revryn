defmodule BillingCore.Billing.RunWorkerTest do
  @moduledoc """
  Billing scheduler fan-out (SPEC §18.1): the daily tick enqueues one
  per-team job carrying that team's local date, and each per-team job
  opens/processes the regular run under the synthetic scheduler scope.
  """

  use BillingCore.DataCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Contracts, Scope}
  alias BillingCore.Billing.{Charge, InvoiceIntent, RunWorker}

  defp perform!(args), do: RunWorker.perform(%Oban.Job{args: args})

  defp enqueued_run_jobs do
    Repo.all(
      from job in Oban.Job,
        where: job.worker == "BillingCore.Billing.RunWorker",
        order_by: job.id
    )
  end

  describe "the daily tick" do
    test "fans out one per-team job with the team's local date, skipping disabled teams" do
      scope_a = billing_scope_fixture()
      scope_b = billing_scope_fixture()

      disabled_scope = billing_scope_fixture()
      disabled_scope.team |> change(status: :disabled) |> Repo.update!()

      assert :ok = perform!(%{})

      jobs = enqueued_run_jobs()
      team_ids = jobs |> Enum.map(& &1.args["team_id"]) |> Enum.sort()
      assert team_ids == Enum.sort([scope_a.team.id, scope_b.team.id])

      # Default team zone is Europe/Copenhagen; the args carry the local date.
      local_today = "Europe/Copenhagen" |> DateTime.now!() |> DateTime.to_date()
      assert Enum.all?(jobs, &(&1.args["invoice_date"] == Date.to_iso8601(local_today)))
    end

    test "re-ticking within the unique window does not duplicate per-team jobs" do
      _scope = billing_scope_fixture()

      assert :ok = perform!(%{})
      assert [_job] = enqueued_run_jobs()

      assert :ok = perform!(%{})
      assert [_job] = enqueued_run_jobs()
    end

    test "an unresolvable team time zone falls back to the UTC date instead of crashing" do
      scope = billing_scope_fixture()
      scope.team |> change(time_zone: "Not/AZone") |> Repo.update!()

      assert :ok = perform!(%{})

      assert [job] = enqueued_run_jobs()
      assert job.args["invoice_date"] == Date.to_iso8601(Date.utc_today())
    end
  end

  describe "a per-team job" do
    setup do
      scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

      plan_version =
        published_plan_version_fixture(scope,
          currency: "DKK",
          interval_unit: :month,
          interval_count: 1,
          amount: "1000.00"
        )

      customer = customer_fixture(scope)
      contract = contract_fixture(scope, %{customer_id: customer.id, start_date: ~D[2026-01-01]})

      {:ok, _subscription} =
        Contracts.start_subscription(scope, %{
          external_id: unique_subscription_external_id(),
          contract_id: contract.id,
          plan_version_id: plan_version.id,
          start_date: ~D[2026-08-01],
          quantity: Decimal.new(1)
        })

      %{scope: scope}
    end

    test "processes the regular run under the scheduler's service scope", %{scope: scope} do
      assert :ok =
               perform!(%{"team_id" => scope.team.id, "invoice_date" => "2026-09-01"})

      assert [intent] = Repo.all(from i in InvoiceIntent, where: i.team_id == ^scope.team.id)
      assert intent.invoice_date == ~D[2026-09-01]
      assert intent.net_amount_minor == 100_000
    end

    test "replaying the same per-team job converges without double billing", %{scope: scope} do
      args = %{"team_id" => scope.team.id, "invoice_date" => "2026-09-01"}

      assert :ok = perform!(args)
      assert :ok = perform!(args)

      assert [_intent] = Repo.all(from i in InvoiceIntent, where: i.team_id == ^scope.team.id)
      assert [_charge] = Repo.all(from c in Charge, where: c.team_id == ^scope.team.id)
    end
  end

  test "system_scope/1 is an audited service principal carrying the billing roles" do
    scope = billing_scope_fixture()

    system = RunWorker.system_scope(scope.team)

    assert %Scope{principal_type: :service, service_credential: %{id: "billing-scheduler"}} =
             system

    assert system.team.id == scope.team.id
    assert system.organization.id == scope.organization.id
    assert :billing_admin in system.team_roles
    assert :finance_operator in system.team_roles
    assert system.correlation_id
  end
end
