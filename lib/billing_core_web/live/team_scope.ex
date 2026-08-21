defmodule BillingCoreWeb.TeamScope do
  @moduledoc """
  LiveView `on_mount` hook resolving the team-scoped authorization context
  for `/teams/:team_id/...` routes (SPEC §13.4, INV-024/025).

  Reads `params["team_id"]`, finds the owning organization, and calls
  `BillingCore.Orgs.resolve_scope/3` — the single authorization entry point.
  On success it assigns `:scope` (a `BillingCore.Scope`) and `:team`; any
  failure redirects to `/` without leaking why (INV-025).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias BillingCore.{Orgs, Repo}
  alias BillingCore.Orgs.Team

  def on_mount(:default, %{"team_id" => team_id}, _session, socket) do
    user = socket.assigns.current_user

    with {:ok, team_uuid} <- Ecto.UUID.cast(team_id),
         %Team{} = team <- Repo.get(Team, team_uuid),
         {:ok, scope} <- Orgs.resolve_scope(user, team.organization_id, team.id) do
      {:cont,
       socket
       |> assign(:scope, scope)
       |> assign(:team, scope.team)}
    else
      _failure ->
        {:halt,
         socket
         |> put_flash(:error, "You do not have access to that team.")
         |> redirect(to: "/")}
    end
  end

  def on_mount(:default, _params, _session, socket) do
    {:halt,
     socket
     |> put_flash(:error, "You do not have access to that team.")
     |> redirect(to: "/")}
  end
end
