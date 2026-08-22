defmodule BillingCoreWeb.GraphQL.Organizations.Types do
  @moduledoc """
  Organization/team membership administration types (BC-TASK-088,
  SPEC §14.5 organizations and membership): invitations (BC-US-144,
  single-use, expiring, hashed at rest), membership directories, role
  changes, and team lifecycle commands.
  """

  use Absinthe.Schema.Notation

  alias BillingCoreWeb.GraphQL.Errors
  alias BillingCoreWeb.GraphQL.Organizations.Resolvers

  @desc "An active organization membership in the admin directory."
  object :organization_membership_record do
    field :id, non_null(:id)
    field :user_id, non_null(:id)
    field :email, :string
    field :roles, non_null(list_of(non_null(:string)))
    field :status, non_null(:string)
    field :created_at, non_null(:datetime)
  end

  @desc "A team membership in the admin directory."
  object :team_membership_record do
    field :id, non_null(:id)
    field :user_id, non_null(:id)
    field :email, :string
    field :roles, non_null(list_of(non_null(:string)))
    field :status, non_null(:string)
    field :created_at, non_null(:datetime)
  end

  @desc "A pending or settled membership invitation."
  object :organization_invitation do
    field :id, non_null(:id)
    field :email, non_null(:string)
    field :organization_roles, non_null(list_of(non_null(:string)))
    field :team_id, :id
    field :team_roles, non_null(list_of(non_null(:string)))
    field :expires_at, non_null(:datetime)
    field :accepted_at, :datetime
    field :revoked_at, :datetime

    field :pending, non_null(:boolean) do
      resolve(&Resolvers.invitation_pending/3)
    end
  end

  ## inviteOrganizationMember

  input_object :invite_organization_member_input do
    field :organization_id, non_null(:id)
    field :email, non_null(:string)

    @desc "organization_owner, organization_admin, or organization_member."
    field :organization_roles, list_of(non_null(:string))
    field :team_id, :id

    @desc "team_admin, billing_admin, finance_operator, auditor, integration_client."
    field :team_roles, list_of(non_null(:string))
    field :client_mutation_id, non_null(:string)
  end

  object :invite_organization_member_success do
    field :invitation, non_null(:organization_invitation)

    @desc "The single-use accept URL — shown once; only a hash is stored."
    field :accept_url, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  union :invite_organization_member_result do
    types([
      :invite_organization_member_success,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :invite_organization_member_success)
    end)
  end

  ## revokeOrganizationInvitation

  input_object :revoke_organization_invitation_input do
    field :organization_id, non_null(:id)
    field :invitation_id, non_null(:id)
    field :client_mutation_id, non_null(:string)
  end

  object :revoke_organization_invitation_success do
    field :invitation, non_null(:organization_invitation)
    field :client_mutation_id, non_null(:string)
  end

  union :revoke_organization_invitation_result do
    types([
      :revoke_organization_invitation_success,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :revoke_organization_invitation_success)
    end)
  end

  ## changeOrganizationRoles

  input_object :change_organization_roles_input do
    field :organization_id, non_null(:id)
    field :membership_id, non_null(:id)

    @desc "organization_owner, organization_admin, or organization_member."
    field :organization_roles, non_null(list_of(non_null(:string)))
    field :client_mutation_id, non_null(:string)
  end

  object :change_organization_roles_success do
    field :membership, non_null(:organization_membership_record)
    field :client_mutation_id, non_null(:string)
  end

  union :change_organization_roles_result do
    types([:change_organization_roles_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :change_organization_roles_success)
    end)
  end

  ## addTeamMember

  input_object :add_team_member_input do
    field :team_id, non_null(:id)

    @desc "An existing user with an active membership in the owning organization."
    field :user_id, non_null(:id)

    @desc "team_admin, billing_admin, finance_operator, auditor, integration_client."
    field :team_roles, non_null(list_of(non_null(:string)))
    field :client_mutation_id, non_null(:string)
  end

  object :add_team_member_success do
    field :membership, non_null(:team_membership_record)
    field :client_mutation_id, non_null(:string)
  end

  union :add_team_member_result do
    types([:add_team_member_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :add_team_member_success)
    end)
  end

  ## changeTeamRoles

  input_object :change_team_roles_input do
    field :team_id, non_null(:id)
    field :membership_id, non_null(:id)

    @desc "team_admin, billing_admin, finance_operator, auditor, integration_client."
    field :team_roles, non_null(list_of(non_null(:string)))
    field :client_mutation_id, non_null(:string)
  end

  object :change_team_roles_success do
    field :membership, non_null(:team_membership_record)
    field :client_mutation_id, non_null(:string)
  end

  union :change_team_roles_result do
    types([:change_team_roles_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :change_team_roles_success)
    end)
  end

  ## removeTeamMember

  input_object :remove_team_member_input do
    field :team_id, non_null(:id)
    field :membership_id, non_null(:id)
    field :client_mutation_id, non_null(:string)
  end

  object :remove_team_member_success do
    field :membership, non_null(:team_membership_record)
    field :client_mutation_id, non_null(:string)
  end

  union :remove_team_member_result do
    types([:remove_team_member_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :remove_team_member_success)
    end)
  end

  ## renameTeam

  input_object :rename_team_input do
    field :team_id, non_null(:id)
    field :name, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :rename_team_success do
    field :team, non_null(:team)
    field :client_mutation_id, non_null(:string)
  end

  union :rename_team_result do
    types([:rename_team_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :rename_team_success)
    end)
  end

  ## archiveTeam

  input_object :archive_team_input do
    field :organization_id, non_null(:id)

    @desc "The team to archive. Named so the scope stays organization-level: an owner/admin need not be a member of the team being archived."
    field :target_team_id, non_null(:id)
    field :client_mutation_id, non_null(:string)
  end

  object :archive_team_success do
    field :team, non_null(:team)
    field :client_mutation_id, non_null(:string)
  end

  union :archive_team_result do
    types([:archive_team_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :archive_team_success)
    end)
  end
end
