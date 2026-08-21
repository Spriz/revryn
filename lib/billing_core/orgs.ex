defmodule BillingCore.Orgs do
  @moduledoc """
  Organizations, teams, memberships, accounts, and scope resolution
  (SPEC §6.3, §9.1.1, §13.3, §13.4, Epic J).

  Structural rules enforced here:

    * organization creation atomically creates its first team plus the
      creator's `organization_owner` and `team_admin` memberships (INV-033,
      BC-US-140);
    * an active organization can never be left with zero active teams — the
      final active team cannot be archived (`{:error, :last_active_team}`);
    * the last active `organization_owner` cannot be removed or demoted
      (`{:error, :last_owner}`);
    * a user's organization membership cannot be removed while they still
      hold active team memberships in that organization
      (`{:error, :active_team_memberships}`);
    * team membership requires an active membership in the owning
      organization (`{:error, :not_organization_member}`);
    * team roles never derive from organization roles — `resolve_scope/3`
      grants team access exclusively from an active team membership.

  Every membership/lifecycle mutation records `BillingCore.Audit` entries
  inside the same transaction. Mutating functions accept an `actor`
  (`BillingCore.Scope` or `:system`) as their last argument for that
  purpose.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Repo, Scope}
  alias BillingCore.Domain.Canonical
  alias BillingCore.Identity.User

  alias BillingCore.Orgs.{
    Account,
    AccountTeamCustomer,
    Organization,
    OrganizationMembership,
    Team,
    TeamMembership,
    TeamSettingsVersion
  }

  alias Ecto.Multi

  @type actor :: Scope.t() | :system

  @default_team_name "Default"
  @default_base_currency "DKK"
  @default_time_zone "Europe/Copenhagen"
  @default_locale "da-DK"

  ## Organization lifecycle

  @doc """
  Creates an organization together with its first team and the creator's
  memberships in one transaction (INV-033, BC-US-140).

  `attrs` requires `:name`; optional keys: `:slug` (derived from the name
  otherwise), `:security_policy`, `:team_name` (default
  `#{inspect(@default_team_name)}` — a bootstrap convenience, never a
  semantic marker), `:team_slug`, `:legal_name` (defaults to the
  organization name), `:base_currency` (#{@default_base_currency}),
  `:time_zone` (#{@default_time_zone}), `:locale` (#{@default_locale}).

  The creator receives `organization_owner` and `team_admin` grants.
  Returns `{:ok, %{organization: _, team: _, organization_membership: _,
  team_membership: _}}` or `{:error, changeset}`.
  """
  @spec create_organization(map() | keyword(), User.t()) ::
          {:ok,
           %{
             organization: Organization.t(),
             team: Team.t(),
             organization_membership: OrganizationMembership.t(),
             team_membership: TeamMembership.t()
           }}
          | {:error, Ecto.Changeset.t()}
  def create_organization(attrs, %User{} = creator) do
    attrs = Map.new(attrs)
    name = attrs[:name]
    team_name = attrs[:team_name] || @default_team_name

    org_changeset =
      Organization.changeset(%Organization{}, %{
        name: name,
        slug: attrs[:slug] || slugify(name),
        security_policy: attrs[:security_policy] || %{}
      })

    Multi.new()
    |> Multi.insert(:organization, org_changeset)
    |> Multi.insert(:team, fn %{organization: org} ->
      Team.changeset(%Team{organization_id: org.id}, %{
        name: team_name,
        slug: attrs[:team_slug] || slugify(team_name),
        legal_name: attrs[:legal_name] || org.name,
        base_currency: attrs[:base_currency] || @default_base_currency,
        time_zone: attrs[:time_zone] || @default_time_zone,
        locale: attrs[:locale] || @default_locale
      })
    end)
    |> Multi.insert(:settings_version, fn %{team: team} ->
      initial_settings_version(team, creator.id)
    end)
    |> Multi.insert(:organization_membership, fn %{organization: org} ->
      OrganizationMembership.changeset(
        %OrganizationMembership{organization_id: org.id, user_id: creator.id},
        %{roles: [:organization_owner], status: :active}
      )
    end)
    |> Multi.insert(:team_membership, fn %{team: team} ->
      TeamMembership.changeset(
        %TeamMembership{team_id: team.id, user_id: creator.id},
        %{roles: [:team_admin], status: :active}
      )
    end)
    |> Multi.run(:audit, fn _repo, changes ->
      %{
        organization: org,
        team: team,
        organization_membership: om,
        team_membership: tm
      } = changes

      scope = %Scope{
        principal_type: :user,
        user: creator,
        organization: org,
        team: team,
        organization_roles: om.roles,
        team_roles: tm.roles,
        platform_admin?: creator.platform_admin
      }

      Audit.record!(scope, "orgs.organization.created",
        aggregate: {"organization", org.id},
        organization_id: org.id,
        team_id: nil,
        payload: %{slug: org.slug}
      )

      Audit.record!(scope, "orgs.team.created",
        aggregate: {"team", team.id},
        organization_id: org.id,
        team_id: team.id,
        payload: %{slug: team.slug}
      )

      Audit.record!(scope, "orgs.organization_membership.created",
        aggregate: {"organization_membership", om.id},
        organization_id: org.id,
        team_id: nil,
        payload: %{user_id: creator.id, roles: om.roles}
      )

      Audit.record!(scope, "orgs.team_membership.created",
        aggregate: {"team_membership", tm.id},
        organization_id: org.id,
        team_id: team.id,
        payload: %{user_id: creator.id, roles: tm.roles}
      )

      {:ok, :recorded}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        {:ok,
         Map.take(changes, [:organization, :team, :organization_membership, :team_membership])}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc "Fetches an organization by ID, raising if absent."
  @spec get_organization!(Ecto.UUID.t()) :: Organization.t()
  def get_organization!(id), do: Repo.get!(Organization, id)

  ## Teams

  @doc """
  Creates an additional team in an active organization.

  `attrs` requires `:name`; `:slug`, `:legal_name`, `:base_currency`,
  `:time_zone`, and `:locale` default as in `create_organization/2`
  (`legal_name` falls back to the team name here).
  """
  @spec create_team(Organization.t(), map() | keyword(), actor()) ::
          {:ok, Team.t()}
          | {:error, :organization_not_active | Ecto.Changeset.t()}
  def create_team(%Organization{} = organization, attrs, actor \\ :system) do
    attrs = Map.new(attrs)

    result =
      Repo.transaction(fn ->
        org = lock_organization!(organization.id)

        if org.status != :active, do: Repo.rollback(:organization_not_active)

        changeset =
          Team.changeset(%Team{organization_id: org.id}, %{
            name: attrs[:name],
            slug: attrs[:slug] || slugify(attrs[:name]),
            legal_name: attrs[:legal_name] || attrs[:name],
            base_currency: attrs[:base_currency] || @default_base_currency,
            time_zone: attrs[:time_zone] || @default_time_zone,
            locale: attrs[:locale] || @default_locale
          })

        case Repo.insert(changeset) do
          {:ok, team} ->
            Repo.insert!(initial_settings_version(team, actor_user_id(actor)))

            audit!(actor, "orgs.team.created",
              aggregate: {"team", team.id},
              organization_id: org.id,
              team_id: team.id,
              payload: %{slug: team.slug}
            )

            team

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    result
  end

  @doc """
  Renames a team. The team's UUID and slug are stable identifiers and are
  unaffected (BC-US-140).
  """
  @spec rename_team(Team.t(), String.t(), actor()) ::
          {:ok, Team.t()} | {:error, Ecto.Changeset.t()}
  def rename_team(%Team{} = team, new_name, actor \\ :system) do
    Repo.transaction(fn ->
      case Repo.update(Team.rename_changeset(team, %{name: new_name})) do
        {:ok, renamed} ->
          audit!(actor, "orgs.team.renamed",
            aggregate: {"team", renamed.id},
            organization_id: renamed.organization_id,
            team_id: renamed.id,
            payload: %{from: team.name, to: renamed.name}
          )

          renamed

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Archives (disables) a team.

  Refuses to archive the final active team of an active organization
  (`{:error, :last_active_team}`, INV-033) — the organization row is locked
  so concurrent archives of the two last teams cannot both succeed.
  Returns `{:error, :not_active}` when the team is already archived.
  """
  @spec archive_team(Team.t(), actor()) ::
          {:ok, Team.t()} | {:error, :last_active_team | :not_active}
  def archive_team(%Team{} = team, actor \\ :system) do
    Repo.transaction(fn ->
      org = lock_organization!(team.organization_id)
      team = Repo.get!(Team, team.id)

      cond do
        team.status != :active ->
          Repo.rollback(:not_active)

        org.status == :active and active_team_count(org.id) <= 1 ->
          Repo.rollback(:last_active_team)

        true ->
          archived =
            team
            |> Ecto.Changeset.change(status: :disabled)
            |> Repo.update!()

          audit!(actor, "orgs.team.archived",
            aggregate: {"team", archived.id},
            organization_id: org.id,
            team_id: archived.id
          )

          archived
      end
    end)
  end

  @doc "Fetches a team by ID, raising if absent."
  @spec get_team!(Ecto.UUID.t()) :: Team.t()
  def get_team!(id), do: Repo.get!(Team, id)

  @doc "Lists the active teams of an organization."
  @spec list_active_teams(Organization.t()) :: [Team.t()]
  def list_active_teams(%Organization{id: org_id}) do
    Repo.all(
      from t in Team,
        where: t.organization_id == ^org_id and t.status == :active,
        order_by: [asc: t.created_at]
    )
  end

  @doc """
  Active teams `user` can enter, across organizations, with `:organization`
  preloaded (dashboard entry points — SPEC §13.4).

  A team qualifies only when every membership step that `resolve_scope/3`
  checks holds: the user's team membership, the owning organization's
  membership, and both the team and organization are active. Ordered by
  organization name, then team name.
  """
  @spec list_user_teams(User.t()) :: [Team.t()]
  def list_user_teams(%User{id: user_id}) do
    Repo.all(
      from t in Team,
        join: tm in TeamMembership,
        on: tm.team_id == t.id,
        join: o in Organization,
        on: o.id == t.organization_id,
        join: om in OrganizationMembership,
        on: om.organization_id == o.id and om.user_id == ^user_id,
        where: tm.user_id == ^user_id and tm.status == :active,
        where: om.status == :active,
        where: t.status == :active and o.status == :active,
        order_by: [asc: o.name, asc: t.name],
        preload: [organization: o]
    )
  end

  ## Organization memberships

  @doc """
  Grants `user` an active organization membership with `roles`.

  Returns `{:error, :already_member}` when the user already has an active
  membership, or `{:error, changeset}` for invalid roles.
  """
  @spec add_organization_member(Organization.t(), User.t(), [atom()], actor()) ::
          {:ok, OrganizationMembership.t()}
          | {:error, :already_member | Ecto.Changeset.t()}
  def add_organization_member(
        %Organization{} = organization,
        %User{} = user,
        roles,
        actor \\ :system
      ) do
    Repo.transaction(fn ->
      changeset =
        OrganizationMembership.changeset(
          %OrganizationMembership{organization_id: organization.id, user_id: user.id},
          %{roles: roles, status: :active}
        )

      case Repo.insert(changeset) do
        {:ok, membership} ->
          audit!(actor, "orgs.organization_membership.created",
            aggregate: {"organization_membership", membership.id},
            organization_id: organization.id,
            team_id: nil,
            payload: %{user_id: user.id, roles: membership.roles}
          )

          membership

        {:error, changeset} ->
          if unique_error?(changeset),
            do: Repo.rollback(:already_member),
            else: Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Replaces the role grants of an active organization membership.

  Demoting the last active `organization_owner` is refused
  (`{:error, :last_owner}`).
  """
  @spec change_organization_roles(OrganizationMembership.t(), [atom()], actor()) ::
          {:ok, OrganizationMembership.t()}
          | {:error, :last_owner | :not_active | Ecto.Changeset.t()}
  def change_organization_roles(%OrganizationMembership{} = membership, roles, actor \\ :system) do
    Repo.transaction(fn ->
      _org = lock_organization!(membership.organization_id)
      membership = Repo.get!(OrganizationMembership, membership.id)
      changeset = OrganizationMembership.changeset(membership, %{roles: roles})
      new_roles = Ecto.Changeset.get_field(changeset, :roles) || []

      cond do
        membership.status != :active ->
          Repo.rollback(:not_active)

        :organization_owner in membership.roles and
          :organization_owner not in new_roles and
            last_active_owner?(membership) ->
          Repo.rollback(:last_owner)

        true ->
          case Repo.update(changeset) do
            {:ok, updated} ->
              audit!(actor, "orgs.organization_membership.roles_changed",
                aggregate: {"organization_membership", updated.id},
                organization_id: updated.organization_id,
                team_id: nil,
                payload: %{user_id: updated.user_id, from: membership.roles, to: updated.roles}
              )

              updated

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc """
  Removes an active organization membership (status `removed`; the row is
  retained as history).

  Refused when the membership is the last active `organization_owner`
  (`{:error, :last_owner}`) or while the user still holds active team
  memberships in the organization (`{:error, :active_team_memberships}` —
  SPEC §13.3: resolve team memberships first).
  """
  @spec remove_organization_member(OrganizationMembership.t(), actor()) ::
          {:ok, OrganizationMembership.t()}
          | {:error, :last_owner | :active_team_memberships | :not_active}
  def remove_organization_member(%OrganizationMembership{} = membership, actor \\ :system) do
    Repo.transaction(fn ->
      _org = lock_organization!(membership.organization_id)
      membership = Repo.get!(OrganizationMembership, membership.id)

      cond do
        membership.status != :active ->
          Repo.rollback(:not_active)

        :organization_owner in membership.roles and last_active_owner?(membership) ->
          Repo.rollback(:last_owner)

        active_team_membership_count(membership.organization_id, membership.user_id) > 0 ->
          Repo.rollback(:active_team_memberships)

        true ->
          removed =
            membership
            |> Ecto.Changeset.change(status: :removed)
            |> Repo.update!()

          audit!(actor, "orgs.organization_membership.removed",
            aggregate: {"organization_membership", removed.id},
            organization_id: removed.organization_id,
            team_id: nil,
            payload: %{user_id: removed.user_id}
          )

          removed
      end
    end)
  end

  ## Team memberships

  @doc """
  Grants `user` an active team membership with `roles`.

  The user must already hold an active membership in the owning
  organization (`{:error, :not_organization_member}`); an existing active
  team membership yields `{:error, :already_member}`.
  """
  @spec add_team_member(Team.t(), User.t(), [atom()], actor()) ::
          {:ok, TeamMembership.t()}
          | {:error, :not_organization_member | :already_member | Ecto.Changeset.t()}
  def add_team_member(%Team{} = team, %User{} = user, roles, actor \\ :system) do
    Repo.transaction(fn ->
      unless active_organization_membership_exists?(team.organization_id, user.id) do
        Repo.rollback(:not_organization_member)
      end

      changeset =
        TeamMembership.changeset(
          %TeamMembership{team_id: team.id, user_id: user.id},
          %{roles: roles, status: :active}
        )

      case Repo.insert(changeset) do
        {:ok, membership} ->
          audit!(actor, "orgs.team_membership.created",
            aggregate: {"team_membership", membership.id},
            organization_id: team.organization_id,
            team_id: team.id,
            payload: %{user_id: user.id, roles: membership.roles}
          )

          membership

        {:error, changeset} ->
          if unique_error?(changeset),
            do: Repo.rollback(:already_member),
            else: Repo.rollback(changeset)
      end
    end)
  end

  @doc "Replaces the role grants of an active team membership."
  @spec change_team_roles(TeamMembership.t(), [atom()], actor()) ::
          {:ok, TeamMembership.t()} | {:error, :not_active | Ecto.Changeset.t()}
  def change_team_roles(%TeamMembership{} = membership, roles, actor \\ :system) do
    Repo.transaction(fn ->
      membership = Repo.get!(TeamMembership, membership.id)

      if membership.status != :active, do: Repo.rollback(:not_active)

      case Repo.update(TeamMembership.changeset(membership, %{roles: roles})) do
        {:ok, updated} ->
          team = Repo.get!(Team, updated.team_id)

          audit!(actor, "orgs.team_membership.roles_changed",
            aggregate: {"team_membership", updated.id},
            organization_id: team.organization_id,
            team_id: team.id,
            payload: %{user_id: updated.user_id, from: membership.roles, to: updated.roles}
          )

          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Removes an active team membership (status `removed`; row retained)."
  @spec remove_team_member(TeamMembership.t(), actor()) ::
          {:ok, TeamMembership.t()} | {:error, :not_active}
  def remove_team_member(%TeamMembership{} = membership, actor \\ :system) do
    Repo.transaction(fn ->
      membership = Repo.get!(TeamMembership, membership.id)

      if membership.status != :active, do: Repo.rollback(:not_active)

      removed =
        membership
        |> Ecto.Changeset.change(status: :removed)
        |> Repo.update!()

      team = Repo.get!(Team, removed.team_id)

      audit!(actor, "orgs.team_membership.removed",
        aggregate: {"team_membership", removed.id},
        organization_id: team.organization_id,
        team_id: team.id,
        payload: %{user_id: removed.user_id}
      )

      removed
    end)
  end

  ## Team settings

  @doc """
  Records a new immutable team settings snapshot and bumps
  `teams.settings_version` (SPEC §13.3 `team_settings_versions`).

  The snapshot stores the canonical SHA-256 of `settings`
  (`BillingCore.Domain.Canonical.hash/1`). The team row is locked so
  concurrent updates serialize and versions never collide.
  """
  @spec update_team_settings(Team.t(), map(), actor()) ::
          {:ok, %{team: Team.t(), settings_version: TeamSettingsVersion.t()}}
  def update_team_settings(%Team{} = team, settings, actor \\ :system) when is_map(settings) do
    Repo.transaction(fn ->
      team =
        Repo.one!(from t in Team, where: t.id == ^team.id, lock: "FOR UPDATE")

      new_version = team.settings_version + 1

      snapshot =
        Repo.insert!(%TeamSettingsVersion{
          team_id: team.id,
          version: new_version,
          settings: settings,
          settings_hash: Canonical.hash(settings),
          created_by: actor_user_id(actor)
        })

      updated_team =
        team
        |> Ecto.Changeset.change(settings_version: new_version)
        |> Repo.update!()

      audit!(actor, "orgs.team.settings_updated",
        aggregate: {"team", team.id},
        organization_id: team.organization_id,
        team_id: team.id,
        payload: %{version: new_version, settings_hash: snapshot.settings_hash}
      )

      %{team: updated_team, settings_version: snapshot}
    end)
  end

  @doc "Returns the latest settings snapshot of `team`, or `nil`."
  @spec current_team_settings(Team.t()) :: TeamSettingsVersion.t() | nil
  def current_team_settings(%Team{id: team_id}) do
    Repo.one(
      from v in TeamSettingsVersion,
        where: v.team_id == ^team_id,
        order_by: [desc: v.version],
        limit: 1
    )
  end

  ## Accounts

  @doc """
  Creates an organization-scoped commercial account (BC-US-142).

  `attrs` requires `:external_id` and `:display_name`; `:metadata` is
  optional. `external_id` is unique per organization.
  """
  @spec create_account(Organization.t(), map() | keyword(), actor()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def create_account(%Organization{} = organization, attrs, actor \\ :system) do
    Repo.transaction(fn ->
      changeset =
        Account.create_changeset(%Account{organization_id: organization.id}, Map.new(attrs))

      case Repo.insert(changeset) do
        {:ok, account} ->
          audit!(actor, "orgs.account.created",
            aggregate: {"account", account.id},
            organization_id: organization.id,
            team_id: nil,
            payload: %{external_id: account.external_id}
          )

          account

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Updates an account's display name/metadata."
  @spec update_account(Account.t(), map() | keyword(), actor()) ::
          {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def update_account(%Account{} = account, attrs, actor \\ :system) do
    Repo.transaction(fn ->
      case Repo.update(Account.update_changeset(account, Map.new(attrs))) do
        {:ok, updated} ->
          audit!(actor, "orgs.account.updated",
            aggregate: {"account", updated.id},
            organization_id: updated.organization_id,
            team_id: nil
          )

          updated

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Archives an account (idempotent). Historical projections remain."
  @spec archive_account(Account.t(), actor()) :: {:ok, Account.t()}
  def archive_account(account, actor \\ :system)

  def archive_account(%Account{status: :archived} = account, _actor), do: {:ok, account}

  def archive_account(%Account{} = account, actor) do
    Repo.transaction(fn ->
      archived =
        account
        |> Ecto.Changeset.change(status: :archived)
        |> Repo.update!()

      audit!(actor, "orgs.account.archived",
        aggregate: {"account", archived.id},
        organization_id: archived.organization_id,
        team_id: nil
      )

      archived
    end)
  end

  @doc """
  Maps `account` to a team-local billing customer (upsert on
  `(account_id, team_id)` — BC-US-142).

  The team must belong to the account's organization
  (`{:error, :cross_organization}`); an account never grants access across
  team boundaries (SPEC §13.4).
  """
  @spec project_account_to_team(Account.t(), Team.t(), Ecto.UUID.t(), actor()) ::
          {:ok, AccountTeamCustomer.t()} | {:error, :cross_organization}
  def project_account_to_team(%Account{} = account, %Team{} = team, customer_id, actor \\ :system) do
    if team.organization_id != account.organization_id do
      {:error, :cross_organization}
    else
      Repo.transaction(fn ->
        projection =
          Repo.insert!(
            %AccountTeamCustomer{
              account_id: account.id,
              team_id: team.id,
              customer_id: customer_id
            },
            on_conflict: {:replace, [:customer_id]},
            conflict_target: [:account_id, :team_id],
            returning: true
          )

        audit!(actor, "orgs.account.projected_to_team",
          aggregate: {"account", account.id},
          organization_id: account.organization_id,
          team_id: team.id,
          payload: %{customer_id: customer_id}
        )

        projection
      end)
    end
  end

  ## Scope resolution

  @doc """
  Resolves a `BillingCore.Scope` for `user` in `organization_id` (and
  optionally `team_id`) — SPEC §9.1.1, §13.4, INV-024/025.

  Authorization requires every step to hold, otherwise
  `{:error, :unauthorized}` with no detail leak:

    * the user is active;
    * the organization exists and is active;
    * the user holds an ACTIVE organization membership;
    * when `team_id` is given: the team belongs to *that* organization, is
      active, and the user holds an ACTIVE team membership.

  Team access is never derived from organization roles, and
  `platform_admin` never bypasses membership checks.
  """
  @spec resolve_scope(User.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, Scope.t()} | {:error, :unauthorized}
  def resolve_scope(%User{} = user, organization_id, team_id \\ nil) do
    with :active <- user.status,
         {:ok, org_id} <- Ecto.UUID.cast(organization_id),
         %Organization{status: :active} = org <- Repo.get(Organization, org_id),
         %OrganizationMembership{} = om <- active_organization_membership(org.id, user.id),
         {:ok, team, team_roles} <- resolve_team(org, user, team_id) do
      {:ok,
       %Scope{
         principal_type: :user,
         user: user,
         organization: org,
         team: team,
         organization_roles: om.roles,
         team_roles: team_roles,
         platform_admin?: user.platform_admin
       }}
    else
      _failure -> {:error, :unauthorized}
    end
  end

  defp resolve_team(_org, _user, nil), do: {:ok, nil, []}

  defp resolve_team(%Organization{} = org, %User{} = user, team_id) do
    with {:ok, team_uuid} <- Ecto.UUID.cast(team_id),
         %Team{} = team <-
           Repo.one(
             from t in Team,
               where:
                 t.id == ^team_uuid and t.organization_id == ^org.id and
                   t.status == :active
           ),
         %TeamMembership{} = tm <-
           Repo.one(
             from m in TeamMembership,
               where:
                 m.team_id == ^team.id and m.user_id == ^user.id and
                   m.status == :active
           ) do
      {:ok, team, tm.roles}
    else
      _failure -> :error
    end
  end

  ## Internal helpers

  defp initial_settings_version(%Team{} = team, created_by) do
    %TeamSettingsVersion{
      team_id: team.id,
      version: 1,
      settings: %{},
      settings_hash: Canonical.hash(%{}),
      created_by: created_by
    }
  end

  defp lock_organization!(org_id) do
    Repo.one!(from o in Organization, where: o.id == ^org_id, lock: "FOR UPDATE")
  end

  defp active_team_count(org_id) do
    Repo.aggregate(
      from(t in Team, where: t.organization_id == ^org_id and t.status == :active),
      :count
    )
  end

  defp active_organization_membership(org_id, user_id) do
    Repo.one(
      from m in OrganizationMembership,
        where:
          m.organization_id == ^org_id and m.user_id == ^user_id and
            m.status == :active
    )
  end

  defp active_organization_membership_exists?(org_id, user_id) do
    not is_nil(active_organization_membership(org_id, user_id))
  end

  defp last_active_owner?(%OrganizationMembership{} = membership) do
    other_owners =
      Repo.aggregate(
        from(m in OrganizationMembership,
          where:
            m.organization_id == ^membership.organization_id and
              m.id != ^membership.id and m.status == :active,
          where: fragment("? = ANY(?)", "organization_owner", m.roles)
        ),
        :count
      )

    other_owners == 0
  end

  defp active_team_membership_count(org_id, user_id) do
    Repo.aggregate(
      from(tm in TeamMembership,
        join: t in Team,
        on: t.id == tm.team_id,
        where:
          t.organization_id == ^org_id and tm.user_id == ^user_id and
            tm.status == :active
      ),
      :count
    )
  end

  defp audit!(actor, event_type, opts), do: Audit.record!(actor, event_type, opts)

  defp actor_user_id(%Scope{user: %{id: id}}), do: id
  defp actor_user_id(_actor), do: nil

  defp unique_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, meta}} -> meta[:constraint] == :unique end)
  end

  defp slugify(nil), do: nil

  defp slugify(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "" do
      "x" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
    else
      slug
    end
  end
end
