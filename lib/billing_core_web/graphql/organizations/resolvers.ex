defmodule BillingCoreWeb.GraphQL.Organizations.Resolvers do
  @moduledoc """
  Membership-administration resolvers (BC-US-144, SPEC §14.5) — thin
  adapters over `BillingCore.Orgs`, which enforces organization-admin /
  team-admin authorization and canonical role validation itself.
  """

  use BillingCoreWeb, :verified_routes

  alias BillingCore.Orgs
  alias BillingCore.Orgs.Invitation
  alias BillingCoreWeb.GraphQL.Errors

  def invitation_pending(invitation, _args, _resolution) do
    {:ok, Invitation.pending?(invitation, DateTime.utc_now())}
  end

  ## Membership directories

  def organization_memberships(_parent, _args, %{context: %{scope: scope}}) do
    case Orgs.list_organization_members(scope) do
      {:ok, members} -> {:ok, Enum.map(members, &membership_record/1)}
      {:error, :unauthorized} -> Errors.unauthorized()
    end
  end

  def team_memberships(_parent, _args, %{context: %{scope: scope}}) do
    case Orgs.list_team_members(scope) do
      {:ok, members} -> {:ok, Enum.map(members, &membership_record/1)}
      {:error, :unauthorized} -> Errors.unauthorized()
    end
  end

  ## Membership mutations

  def change_organization_roles(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, membership_id} <- cast_uuid(input.membership_id),
         {:ok, membership} <-
           Orgs.admin_change_organization_roles(scope, membership_id, input.organization_roles) do
      {:ok, %{membership: mutated_record(membership), client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def add_team_member(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    case Orgs.admin_add_team_member(scope, input.user_id, input.team_roles) do
      {:ok, membership} ->
        {:ok, %{membership: mutated_record(membership), client_mutation_id: cmid}}

      {:error, reason} ->
        {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def change_team_roles(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, membership_id} <- cast_uuid(input.membership_id),
         {:ok, membership} <-
           Orgs.admin_change_team_roles(scope, membership_id, input.team_roles) do
      {:ok, %{membership: mutated_record(membership), client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def remove_team_member(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, membership_id} <- cast_uuid(input.membership_id),
         {:ok, membership} <- Orgs.admin_remove_team_member(scope, membership_id) do
      {:ok, %{membership: mutated_record(membership), client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def rename_team(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    case Orgs.admin_rename_team(scope, input.name) do
      {:ok, team} -> {:ok, %{team: team, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def archive_team(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, team_id} <- cast_uuid(input.target_team_id),
         {:ok, team} <- Orgs.admin_archive_team(scope, team_id) do
      {:ok, %{team: team, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def organization_invitations(_parent, _args, %{context: %{scope: scope}}) do
    case Orgs.list_invitations(scope) do
      {:ok, invitations} -> {:ok, invitations}
      {:error, :unauthorized} -> Errors.unauthorized()
    end
  end

  def invite_organization_member(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    case Orgs.invite_member(scope, %{
           email: input.email,
           organization_roles: input[:organization_roles] || [],
           team_id: input[:team_id],
           team_roles: input[:team_roles] || [],
           accept_url_fun: &accept_url/1
         }) do
      {:ok, %{invitation: invitation, token: token}} ->
        {:ok,
         %{
           invitation: invitation,
           accept_url: accept_url(token),
           client_mutation_id: cmid
         }}

      {:error, reason} ->
        {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def revoke_organization_invitation(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, uuid} <- cast_uuid(input.invitation_id),
         {:ok, invitation} <- Orgs.revoke_invitation(scope, uuid) do
      {:ok, %{invitation: invitation, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  defp accept_url(token), do: url(~p"/invitations/#{token}")

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp membership_record(%{membership: membership, email: email}) do
    %{
      id: membership.id,
      user_id: membership.user_id,
      email: email,
      roles: Enum.map(membership.roles, &to_string/1),
      status: to_string(membership.status),
      created_at: membership.created_at
    }
  end

  # Mutation results carry the bare membership; the directory record wants
  # the member's primary email too.
  defp mutated_record(membership) do
    email =
      BillingCore.Repo.get_by(BillingCore.Identity.UserEmail,
        user_id: membership.user_id,
        primary: true
      )

    membership_record(%{membership: membership, email: email && email.email})
  end
end
