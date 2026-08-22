defmodule BillingCoreWeb.Features.Organization.MembersLive do
  @moduledoc """
  Team membership administration (BC-US-141/143/144): active members with
  explicit role grants, team-admin role changes and removal, and — for
  organization admins — the invitation flow with pending-invitation
  management. Every mutation runs the scoped domain commands; roles shown
  are exactly what `resolve_scope/3` grants.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Orgs
  alias BillingCore.Orgs.TeamMembership
  alias BillingCore.Scope
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:members} />

      <.header>
        Members
        <:subtitle>
          Roles are explicit per team and never leak across teams or organizations; a role in
          this team grants nothing anywhere else.
        </:subtitle>
      </.header>

      <div class="mb-6 rounded-lg border border-base-300 p-4">
        <h2 class="mb-2 font-semibold">Team members</h2>
        <.table id="team-members" rows={@members}>
          <:col :let={row} label="Member">
            <span class="font-medium">{row.email || "(no primary email)"}</span>
            <span
              :if={row.membership.user_id == @scope.user.id}
              class="badge badge-ghost badge-sm ml-1"
            >
              you
            </span>
          </:col>
          <:col :let={row} label="Roles">
            <%= if @can_admin? do %>
              <form
                id={"roles-form-#{row.membership.id}"}
                phx-change="change_roles"
                phx-value-membership_id={row.membership.id}
              >
                <input type="hidden" name="membership_id" value={row.membership.id} />
                <div class="flex flex-wrap gap-2">
                  <label
                    :for={role <- @all_roles}
                    class="flex cursor-pointer items-center gap-1 text-xs"
                  >
                    <input
                      type="checkbox"
                      name="roles[]"
                      value={role}
                      checked={role in row.membership.roles}
                      class="checkbox checkbox-xs"
                    />
                    {role}
                  </label>
                </div>
              </form>
            <% else %>
              <div class="flex flex-wrap gap-1">
                <span :for={role <- row.membership.roles} class="badge badge-outline badge-sm">
                  {role}
                </span>
              </div>
            <% end %>
          </:col>
          <:col :let={row} label="Since">{format_dt(row.membership.created_at)}</:col>
          <:action :let={row}>
            <button
              :if={@can_admin? and row.membership.user_id != @scope.user.id}
              id={"remove-member-#{row.membership.id}"}
              phx-click="remove_member"
              phx-value-membership_id={row.membership.id}
              data-confirm="Remove this member from the team? Their organization membership and other teams are untouched."
              class="link text-error"
            >
              Remove
            </button>
          </:action>
        </.table>
      </div>

      <div :if={@can_invite?} class="mb-6 rounded-lg border border-base-300 p-4">
        <h2 class="mb-2 font-semibold">Invite to this team</h2>
        <p class="mb-3 text-sm opacity-70">
          The invitation is a single-use, expiring link bound to the invited email address and
          scoped to exactly the roles below (BC-US-144). An existing Revryn user is linked —
          never duplicated.
        </p>
        <.form for={@invite_form} id="invite-form" phx-submit="invite">
          <div class="flex flex-wrap items-end gap-2">
            <.input field={@invite_form[:email]} type="email" label="Email" required />
            <.input
              field={@invite_form[:roles]}
              type="select"
              multiple
              label="Team roles"
              options={@all_roles}
            />
            <.button variant="primary" phx-disable-with="Creating invitation…">Invite</.button>
          </div>
        </.form>
        <div
          :if={@last_invite_url}
          id="invite-link"
          class="mt-3 rounded border border-base-300 bg-base-200 p-3 text-xs"
        >
          <p class="mb-1 font-semibold">
            Invitation created{if @last_invite_delivery == :sent,
              do: " and emailed",
              else: " — email delivery failed, share the link directly"}:
          </p>
          <code class="break-all">{@last_invite_url}</code>
          <p class="mt-1 opacity-60">Shown once; only a hash is stored.</p>
        </div>

        <div :if={@pending_invitations != []} class="mt-4">
          <h3 class="mb-1 text-sm font-semibold">Pending invitations</h3>
          <ul class="space-y-1 text-sm" id="pending-invitations">
            <li :for={invitation <- @pending_invitations} class="flex items-center gap-2">
              <span>{invitation.email}</span>
              <span class="text-xs opacity-60">expires {format_dt(invitation.expires_at)}</span>
              <button
                id={"revoke-invitation-#{invitation.id}"}
                phx-click="revoke_invitation"
                phx-value-invitation_id={invitation.id}
                class="link text-xs"
              >
                Revoke
              </button>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok,
     socket
     |> assign(
       page_title: "Members",
       can_admin?: Scope.has_team_role?(scope, [:team_admin]),
       can_invite?:
         Scope.has_organization_role?(scope, [:organization_owner, :organization_admin]),
       all_roles: TeamMembership.roles(),
       invite_form: to_form(%{"email" => "", "roles" => ["auditor"]}, as: "invite"),
       last_invite_url: nil,
       last_invite_delivery: nil
     )
     |> load_members()}
  end

  def handle_event("change_roles", params, socket) do
    membership_id = params["membership_id"]
    roles = Map.get(params, "roles", [])

    case Orgs.admin_change_team_roles(socket.assigns.scope, membership_id, roles) do
      {:ok, _membership} ->
        {:noreply,
         socket |> put_flash(:info, "Roles updated — the change is audited.") |> load_members()}

      {:error, :invalid_roles} ->
        {:noreply,
         socket
         |> put_flash(:error, "A member needs at least one role; remove them instead.")
         |> load_members()}

      {:error, reason} ->
        {:noreply,
         socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> load_members()}
    end
  end

  def handle_event("remove_member", %{"membership_id" => membership_id}, socket) do
    case Orgs.admin_remove_team_member(socket.assigns.scope, membership_id) do
      {:ok, _membership} ->
        {:noreply, socket |> put_flash(:info, "Member removed from this team.") |> load_members()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  def handle_event("invite", %{"invite" => params}, socket) do
    case Orgs.invite_member(socket.assigns.scope, %{
           email: params["email"],
           team_id: socket.assigns.team.id,
           team_roles: List.wrap(params["roles"]),
           accept_url_fun: fn token -> url(~p"/invitations/#{token}") end
         }) do
      {:ok, %{token: token, delivery: delivery}} ->
        {:noreply,
         socket
         |> assign(
           last_invite_url: url(~p"/invitations/#{token}"),
           last_invite_delivery: delivery
         )
         |> put_flash(:info, "Invitation created.")
         |> load_members()}

      {:error, :invalid_email} ->
        {:noreply, put_flash(socket, :error, "Enter a valid email address.")}

      {:error, :invalid_roles} ->
        {:noreply, put_flash(socket, :error, "Pick at least one valid team role.")}

      {:error, :no_grants} ->
        {:noreply, put_flash(socket, :error, "Pick at least one team role to grant.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  def handle_event("revoke_invitation", %{"invitation_id" => invitation_id}, socket) do
    case Orgs.revoke_invitation(socket.assigns.scope, invitation_id) do
      {:ok, _invitation} ->
        {:noreply, socket |> put_flash(:info, "Invitation revoked.") |> load_members()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  defp load_members(socket) do
    scope = socket.assigns.scope
    {:ok, members} = Orgs.list_team_members(scope)

    pending =
      case Orgs.list_invitations(scope) do
        {:ok, invitations} ->
          now = DateTime.utc_now()

          Enum.filter(invitations, fn invitation ->
            invitation.team_id == socket.assigns.team.id and
              BillingCore.Orgs.Invitation.pending?(invitation, now)
          end)

        {:error, :unauthorized} ->
          []
      end

    assign(socket, members: members, pending_invitations: pending)
  end
end
