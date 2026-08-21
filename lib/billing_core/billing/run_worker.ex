defmodule BillingCore.Billing.RunWorker do
  @moduledoc """
  Scheduled billing-run creation (SPEC §18.1, machine actor "Billing
  scheduler" per §6.2).

  The daily tick fans out one job per active team with that team's local
  date; each per-team job opens/processes the regular run under a synthetic
  scheduler scope. Uniqueness comes from the run-key constraint plus Oban
  uniqueness on the per-team args.
  """

  use Oban.Worker, queue: :billing, max_attempts: 5, unique: [period: 3600]

  import Ecto.Query

  alias BillingCore.{Repo, Scope}
  alias BillingCore.Billing.Scheduler
  alias BillingCore.Orgs.{Organization, Team}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"team_id" => team_id, "invoice_date" => date_string}}) do
    team = Repo.get!(Team, team_id)
    invoice_date = Date.from_iso8601!(date_string)

    {:ok, _result} = Scheduler.process_regular_run(system_scope(team), invoice_date)
    :ok
  end

  def perform(%Oban.Job{args: _tick}) do
    teams = Repo.all(from t in Team, where: t.status == :active)

    for team <- teams do
      %{"team_id" => team.id, "invoice_date" => Date.to_iso8601(team_today(team))}
      |> new()
      |> Oban.insert!()
    end

    :ok
  end

  @doc """
  Synthetic scope for the billing scheduler machine actor. It carries the
  billing role required by run commands and is audited as a service
  principal; it exists only for scheduler-internal work and is never derived
  from user input.
  """
  @spec system_scope(Team.t()) :: Scope.t()
  def system_scope(%Team{} = team) do
    organization = Repo.get!(Organization, team.organization_id)

    %Scope{
      principal_type: :service,
      service_credential: %{id: "billing-scheduler"},
      organization: organization,
      team: team,
      team_roles: [:billing_admin, :finance_operator],
      correlation_id: Ecto.UUID.generate()
    }
  end

  defp team_today(team) do
    case DateTime.now(team.time_zone) do
      {:ok, dt} -> DateTime.to_date(dt)
      {:error, _} -> Date.utc_today()
    end
  end
end
