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

  require Logger

  alias BillingCore.{Audit, Repo, Scope}
  alias BillingCore.Domain.Canonical
  alias BillingCore.Identity.User

  alias BillingCore.Orgs.{
    Account,
    AccountTeamCustomer,
    Invitation,
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
  # Dialyzer false positive: the literal Multi.new() loses MapSet's
  # opaqueness when inlined into the Multi.insert call.
  @dialyzer {:no_opaque, create_organization: 2}
  @dialyzer {:no_opaque, create_organization_multi: 2}
  def create_organization(attrs, %User{} = creator) do
    attrs = Map.new(attrs)

    attrs
    |> create_organization_multi(creator)
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        {:ok,
         Map.take(changes, [:organization, :team, :organization_membership, :team_membership])}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp create_organization_multi(attrs, creator) do
    Multi.new()
    |> Multi.insert(:organization, new_organization_changeset(attrs))
    |> Multi.insert(:team, fn %{organization: org} ->
      first_team_changeset(attrs, org)
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
      record_creation_audit(changes, creator)
    end)
  end

  defp new_organization_changeset(attrs) do
    name = attrs[:name]

    Organization.changeset(%Organization{}, %{
      name: name,
      slug: attrs[:slug] || slugify(name),
      security_policy: attrs[:security_policy] || %{}
    })
  end

  defp first_team_changeset(attrs, org) do
    team_name = attrs[:team_name] || @default_team_name

    Team.changeset(%Team{organization_id: org.id}, %{
      name: team_name,
      slug: attrs[:team_slug] || slugify(team_name),
      legal_name: attrs[:legal_name] || org.name,
      base_currency: attrs[:base_currency] || @default_base_currency,
      time_zone: attrs[:time_zone] || @default_time_zone,
      locale: attrs[:locale] || @default_locale
    })
  end

  defp record_creation_audit(changes, creator) do
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

  @doc "Organization ids where `user` holds an active owner/admin membership."
  @spec list_admin_organization_ids(User.t()) :: MapSet.t(Ecto.UUID.t())
  def list_admin_organization_ids(%User{} = user) do
    Repo.all(
      from m in OrganizationMembership,
        where: m.user_id == ^user.id and m.status == :active,
        select: {m.organization_id, m.roles}
    )
    |> Enum.filter(fn {_org_id, roles} ->
      :organization_owner in roles or :organization_admin in roles
    end)
    |> MapSet.new(fn {org_id, _roles} -> org_id end)
  end

  @doc """
  Active team memberships with each member's primary email, for the
  membership administration surface (BC-US-141). Requires a team-scoped
  member of the team (any role); mutations stay behind the admin commands.
  """
  @spec list_team_members(Scope.t()) ::
          {:ok, [%{membership: TeamMembership.t(), email: String.t() | nil}]}
          | {:error, :unauthorized}
  def list_team_members(%Scope{team: %Team{id: team_id}} = scope) do
    if Scope.team_scoped?(scope) do
      memberships =
        Repo.all(
          from m in TeamMembership,
            where: m.team_id == ^team_id and m.status == :active,
            order_by: [asc: m.created_at]
        )

      {:ok, attach_primary_emails(memberships)}
    else
      {:error, :unauthorized}
    end
  end

  def list_team_members(_scope), do: {:error, :unauthorized}

  @doc """
  Active organization memberships with each member's primary email
  (SPEC §14.5 `organizationMemberships`). Requires an organization
  owner/admin scope — the directory exposes member emails.
  """
  @spec list_organization_members(Scope.t()) ::
          {:ok, [%{membership: OrganizationMembership.t(), email: String.t() | nil}]}
          | {:error, :unauthorized}
  def list_organization_members(%Scope{} = scope) do
    with :ok <- authorize_org_admin(scope) do
      memberships =
        Repo.all(
          from m in OrganizationMembership,
            where: m.organization_id == ^scope.organization.id and m.status == :active,
            order_by: [asc: m.created_at]
        )

      {:ok, attach_primary_emails(memberships)}
    end
  end

  @doc """
  Organization-admin command: replaces a member's organization roles
  (SPEC §14.5 `changeOrganizationRoles`). The membership must belong to
  the scope's organization; demoting the last active owner is refused by
  `change_organization_roles/3`.
  """
  @spec admin_change_organization_roles(Scope.t(), Ecto.UUID.t(), [String.t() | atom()]) ::
          {:ok, OrganizationMembership.t()} | {:error, term()}
  def admin_change_organization_roles(%Scope{} = scope, membership_id, roles) do
    with :ok <- authorize_org_admin(scope),
         {:ok, cast} <- cast_roles(roles, OrganizationMembership.roles()),
         :ok <- ensure_nonempty_roles(cast),
         {:ok, membership} <- fetch_organization_membership(scope, membership_id) do
      change_organization_roles(membership, cast, scope)
    end
  end

  @doc """
  Team-admin command: adds an existing organization member to the scope's
  team (SPEC §14.5 `addTeamMember`). The user must already hold an active
  membership in the owning organization — team access is never implicit
  (INV-024); `add_team_member/4` enforces it.
  """
  @spec admin_add_team_member(Scope.t(), Ecto.UUID.t(), [String.t() | atom()]) ::
          {:ok, TeamMembership.t()} | {:error, term()}
  def admin_add_team_member(%Scope{} = scope, user_id, roles) do
    with :ok <- authorize_team_admin(scope),
         {:ok, cast} <- cast_roles(roles, TeamMembership.roles()),
         :ok <- ensure_nonempty_roles(cast),
         {:ok, user} <- fetch_active_user(user_id) do
      add_team_member(scope.team, user, cast, scope)
    end
  end

  @doc "Team-admin command: renames the scope's team (SPEC §14.5 `renameTeam`)."
  @spec admin_rename_team(Scope.t(), String.t()) ::
          {:ok, Team.t()} | {:error, term()}
  def admin_rename_team(%Scope{} = scope, new_name) do
    with :ok <- authorize_team_admin(scope) do
      rename_team(scope.team, new_name, scope)
    end
  end

  @doc """
  Organization-admin command: archives a team of the scope's organization
  (SPEC §14.5 `archiveTeam`). The final active team of an active
  organization stays protected by `archive_team/2` (INV-033).
  """
  @spec admin_archive_team(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Team.t()} | {:error, term()}
  def admin_archive_team(%Scope{} = scope, team_id) do
    with :ok <- authorize_org_admin(scope),
         {:ok, team} <- fetch_organization_team(scope, team_id) do
      archive_team(team, scope)
    end
  end

  @doc """
  Team-admin command: changes a member's roles in the scope's team
  (BC-US-141). Roles are cast against the canonical set; the membership
  must belong to the scope's team.
  """
  @spec admin_change_team_roles(Scope.t(), Ecto.UUID.t(), [String.t() | atom()]) ::
          {:ok, TeamMembership.t()} | {:error, term()}
  def admin_change_team_roles(%Scope{} = scope, membership_id, roles) do
    with :ok <- authorize_team_admin(scope),
         {:ok, cast} <- cast_roles(roles, TeamMembership.roles()),
         :ok <- ensure_nonempty_roles(cast),
         {:ok, membership} <- fetch_team_membership(scope, membership_id) do
      change_team_roles(membership, cast, scope)
    end
  end

  @doc "Team-admin command: removes a member from the scope's team (BC-US-141)."
  @spec admin_remove_team_member(Scope.t(), Ecto.UUID.t()) ::
          {:ok, TeamMembership.t()} | {:error, term()}
  def admin_remove_team_member(%Scope{} = scope, membership_id) do
    with :ok <- authorize_team_admin(scope),
         {:ok, membership} <- fetch_team_membership(scope, membership_id) do
      remove_team_member(membership, scope)
    end
  end

  defp authorize_team_admin(%Scope{} = scope) do
    if Scope.team_scoped?(scope) and Scope.has_team_role?(scope, [:team_admin]),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp ensure_nonempty_roles([]), do: {:error, :invalid_roles}
  defp ensure_nonempty_roles(_roles), do: :ok

  defp fetch_team_membership(%Scope{team: %Team{id: team_id}}, membership_id) do
    case Repo.get_by(TeamMembership, id: membership_id, team_id: team_id, status: :active) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  end

  defp fetch_organization_membership(%Scope{organization: %Organization{id: org_id}}, id) do
    case Repo.get_by(OrganizationMembership, id: id, organization_id: org_id, status: :active) do
      nil -> {:error, :not_found}
      membership -> {:ok, membership}
    end
  end

  defp fetch_organization_team(%Scope{organization: %Organization{id: org_id}}, team_id) do
    case Repo.get_by(Team, id: team_id, organization_id: org_id) do
      nil -> {:error, :not_found}
      team -> {:ok, team}
    end
  end

  defp fetch_active_user(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} ->
        case Repo.get(User, uuid) do
          %User{status: :active} = user -> {:ok, user}
          _other -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp attach_primary_emails(memberships) do
    user_ids = Enum.map(memberships, & &1.user_id)

    emails =
      Repo.all(
        from e in BillingCore.Identity.UserEmail,
          where: e.user_id in ^user_ids and e.primary == true,
          select: {e.user_id, e.email}
      )
      |> Map.new()

    Enum.map(memberships, fn membership ->
      %{membership: membership, email: Map.get(emails, membership.user_id)}
    end)
  end

  ## Invitations (BC-US-144)

  @invitation_ttl_days 7

  @doc """
  Invites `email` to organization/team memberships (BC-US-144). Requires an
  organization owner/admin scope on the target organization. Attrs:
  `:email` (required), `:organization_roles`, `:team_id` + `:team_roles`
  (the team must belong to the scope's organization; at least one role
  grant overall). Returns the invitation and the raw single-use token —
  the only moment it exists; only its SHA-256 is stored.

  When `:accept_url_fun` is given, an invitation email is delivered
  best-effort through the mail platform; delivery failure never voids the
  invitation (the returned token can be shared out of band).
  """
  @spec invite_member(Scope.t(), map() | keyword()) ::
          {:ok,
           %{invitation: Invitation.t(), token: String.t(), delivery: :sent | :failed | :skipped}}
          | {:error, term()}
  def invite_member(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs)

    with :ok <- authorize_org_admin(scope),
         {:ok, email} <- cast_invitation_email(attrs[:email]),
         {:ok, org_roles} <-
           cast_roles(attrs[:organization_roles] || [], OrganizationMembership.roles()),
         {:ok, team, team_roles} <- cast_invitation_team(scope, attrs),
         :ok <- ensure_invitation_grants(org_roles, team, team_roles) do
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      {:ok, invitation} =
        Repo.transaction(fn ->
          invitation =
            Repo.insert!(%Invitation{
              organization_id: scope.organization.id,
              team_id: team && team.id,
              email: email,
              organization_roles: Enum.map(org_roles, &Atom.to_string/1),
              team_roles: Enum.map(team_roles, &Atom.to_string/1),
              token_hash: hash_invitation_token(token),
              invited_by: scope.user && scope.user.id,
              expires_at: DateTime.add(DateTime.utc_now(), @invitation_ttl_days, :day)
            })

          audit!(scope, "orgs.invitation.created",
            aggregate: {"organization_invitation", invitation.id},
            organization_id: scope.organization.id,
            team_id: team && team.id,
            payload: %{
              email: email,
              organization_roles: invitation.organization_roles,
              team_roles: invitation.team_roles
            }
          )

          invitation
        end)

      delivery = deliver_invitation(invitation, token, attrs[:accept_url_fun])
      {:ok, %{invitation: invitation, token: token, delivery: delivery}}
    end
  end

  @doc """
  Accepts an invitation for the authenticated `user` (BC-US-144). The raw
  token is hashed for lookup; the invitation must be pending and its email
  must belong to the user — the grant links the existing global identity,
  it never creates a duplicate. Membership grants are additive within the
  invited organization/team only.
  """
  @spec accept_invitation(User.t(), String.t()) ::
          {:ok, Invitation.t()} | {:error, :invalid_invitation | :email_mismatch | term()}
  def accept_invitation(%User{} = user, token) when is_binary(token) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      invitation =
        Repo.one(
          from i in Invitation,
            where: i.token_hash == ^hash_invitation_token(token),
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(invitation) or not Invitation.pending?(invitation, now) ->
          Repo.rollback(:invalid_invitation)

        not user_owns_email?(user, invitation.email) ->
          Repo.rollback(:email_mismatch)

        true ->
          apply_invitation_grants!(user, invitation)

          accepted =
            invitation
            |> Ecto.Changeset.change(accepted_at: now, accepted_user_id: user.id)
            |> Repo.update!()

          audit!(:system, "orgs.invitation.accepted",
            aggregate: {"organization_invitation", accepted.id},
            organization_id: accepted.organization_id,
            team_id: accepted.team_id,
            payload: %{user_id: user.id, email: accepted.email}
          )

          accepted
      end
    end)
  end

  @doc "Revokes a pending invitation of the scope's organization."
  @spec revoke_invitation(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Invitation.t()} | {:error, term()}
  def revoke_invitation(%Scope{} = scope, invitation_id) do
    with :ok <- authorize_org_admin(scope) do
      Repo.transaction(fn ->
        invitation =
          Repo.one(
            from i in Invitation,
              where:
                i.id == ^invitation_id and i.organization_id == ^scope.organization.id and
                  is_nil(i.accepted_at) and is_nil(i.revoked_at),
              lock: "FOR UPDATE"
          ) || Repo.rollback(:not_found)

        revoked =
          invitation
          |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
          |> Repo.update!()

        audit!(scope, "orgs.invitation.revoked",
          aggregate: {"organization_invitation", revoked.id},
          organization_id: revoked.organization_id,
          team_id: revoked.team_id,
          payload: %{email: revoked.email}
        )

        revoked
      end)
    end
  end

  @doc "Invitations of the scope's organization, newest first."
  @spec list_invitations(Scope.t()) :: {:ok, [Invitation.t()]} | {:error, :unauthorized}
  def list_invitations(%Scope{} = scope) do
    with :ok <- authorize_org_admin(scope) do
      {:ok,
       Repo.all(
         from i in Invitation,
           where: i.organization_id == ^scope.organization.id,
           order_by: [desc: i.created_at]
       )}
    end
  end

  defp authorize_org_admin(%Scope{organization: %Organization{}} = scope) do
    if Scope.has_organization_role?(scope, [:organization_owner, :organization_admin]),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp authorize_org_admin(_scope), do: {:error, :unauthorized}

  defp cast_invitation_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    if normalized =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      do: {:ok, normalized},
      else: {:error, :invalid_email}
  end

  defp cast_invitation_email(_email), do: {:error, :invalid_email}

  # Role inputs may arrive as strings from UI/API; resolve against the
  # canonical sets without String.to_atom/1.
  defp cast_roles(roles, valid) when is_list(roles) do
    cast =
      Enum.map(roles, fn role ->
        Enum.find(valid, &(&1 == role or Atom.to_string(&1) == role))
      end)

    if Enum.any?(cast, &is_nil/1), do: {:error, :invalid_roles}, else: {:ok, Enum.uniq(cast)}
  end

  defp cast_roles(_roles, _valid), do: {:error, :invalid_roles}

  defp cast_invitation_team(scope, attrs) do
    case attrs[:team_id] do
      nil ->
        {:ok, nil, []}

      team_id ->
        with %Team{} = team <- Repo.get(Team, team_id),
             true <- team.organization_id == scope.organization.id,
             {:ok, team_roles} <- cast_roles(attrs[:team_roles] || [], TeamMembership.roles()) do
          {:ok, team, team_roles}
        else
          {:error, reason} -> {:error, reason}
          _other -> {:error, :team_not_in_organization}
        end
    end
  end

  defp ensure_invitation_grants(org_roles, team, team_roles) do
    cond do
      org_roles != [] -> :ok
      team != nil and team_roles != [] -> :ok
      true -> {:error, :no_grants}
    end
  end

  defp apply_invitation_grants!(user, invitation) do
    organization = Repo.get!(Organization, invitation.organization_id)
    {:ok, org_roles} = cast_roles(invitation.organization_roles, OrganizationMembership.roles())

    base_org_roles = if org_roles == [], do: [:organization_member], else: org_roles

    case Repo.get_by(OrganizationMembership,
           organization_id: organization.id,
           user_id: user.id
         ) do
      nil ->
        {:ok, _membership} = add_organization_member(organization, user, base_org_roles)

      %OrganizationMembership{} = membership ->
        merged = Enum.uniq(membership.roles ++ org_roles)

        if merged != membership.roles or membership.status != :active do
          {:ok, _} =
            membership
            |> Ecto.Changeset.change(status: :active)
            |> Repo.update!()
            |> change_organization_roles(merged)
        end
    end

    if invitation.team_id do
      team = Repo.get!(Team, invitation.team_id)
      {:ok, team_roles} = cast_roles(invitation.team_roles, TeamMembership.roles())

      case Repo.get_by(TeamMembership, team_id: team.id, user_id: user.id) do
        nil ->
          {:ok, _membership} = add_team_member(team, user, team_roles)

        %TeamMembership{} = membership ->
          merged = Enum.uniq(membership.roles ++ team_roles)

          {:ok, _} =
            membership
            |> Ecto.Changeset.change(status: :active)
            |> Repo.update!()
            |> change_team_roles(merged)
      end
    end

    :ok
  end

  defp user_owns_email?(user, invitation_email) do
    Repo.exists?(
      from e in BillingCore.Identity.UserEmail,
        where:
          e.user_id == ^user.id and
            fragment("lower(?)", e.email) == ^String.downcase(invitation_email)
    )
  end

  defp hash_invitation_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp deliver_invitation(_invitation, _token, nil), do: :skipped

  defp deliver_invitation(invitation, token, accept_url_fun)
       when is_function(accept_url_fun, 1) do
    organization = Repo.get!(Organization, invitation.organization_id)

    email =
      BillingCore.Notifications.build!("invitation", %{
        "to" => invitation.email,
        "organization_name" => organization.name,
        "url" => accept_url_fun.(token)
      })

    # Delivery is best-effort: the invitation link shown in the UI is the
    # primary path, so a crashing mail transport must degrade to :failed
    # rather than take down the caller (e.g. the members LiveView).
    try do
      case BillingCore.Mailer.deliver(email) do
        {:ok, _metadata} -> :sent
        {:error, _reason} -> :failed
      end
    catch
      kind, reason ->
        Logger.warning("invitation email delivery crashed: #{inspect({kind, reason})}")
        :failed
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
