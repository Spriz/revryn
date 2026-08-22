defmodule BillingCore.Demo do
  @moduledoc """
  Durable setup and lifecycle for the isolated Revryn demo workspace.

  Provisioning has two durable phases: rows commit in `:provisioning`, then
  the local fake provider starts and validation promotes them to `:active`.
  Demo ERP is single-node only; distributed nodes could hydrate conflicting
  in-memory provider state and are rejected with `:demo_requires_single_node`.
  """

  import Ecto.Query

  alias BillingCore.{Audit, ERP, Orgs, Outbox, Repo, Scope}
  alias BillingCore.Demo.{FakeERPInstance, FakeERPInstances, Workspace}
  alias BillingCore.Domain.Canonical
  alias BillingCore.ERP.Connection
  alias BillingCore.Identity.User
  alias BillingCore.Orgs.{Organization, Team, TeamMembership}

  @scenario_version "northstar-v1"
  @demo_roles [:team_admin, :billing_admin, :finance_operator, :auditor]
  @resumable_states [:provisioning, :active]

  @type bundle :: %{
          workspace: Workspace.t(),
          organization: Organization.t(),
          team: Team.t(),
          scope: Scope.t(),
          connection: Connection.t()
        }

  @doc "A test-injectable check preventing fake-provider split brain in a cluster."
  @spec single_node?() :: boolean()
  def single_node? do
    Application.get_env(:billing_core, :demo_node_lister, &Node.list/0).() == []
  end

  @doc "Whether the opt-in demo workspace feature is enabled for this runtime."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:billing_core, :demo_erp_enabled, false)

  @spec start_workspace(User.t()) :: {:ok, bundle()} | {:error, term()}
  def start_workspace(%User{} = user) do
    with :ok <- public_user_allowed(user),
         {:ok, workspace} <- provision_phase_a(user, nil) do
      activate_workspace(user, workspace.id)
    end
  end

  @spec resume_workspace(User.t()) :: {:ok, bundle()} | {:error, term()}
  def resume_workspace(%User{} = user) do
    with :ok <- public_user_allowed(user),
         %Workspace{} = workspace <- Repo.one(resumable_workspace_query(user.id)),
         {:ok, bundle} <- activate_workspace(user, workspace.id) do
      {:ok, bundle}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @spec active_workspace(User.t()) :: {:ok, bundle()} | {:error, term()}
  def active_workspace(%User{} = user) do
    with :ok <- public_user_allowed(user),
         %Workspace{} = workspace <- Repo.one(active_workspace_query(user.id)) do
      bundle_for(user, workspace)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @spec workspace_for_scope(Scope.t()) :: {:ok, bundle()} | {:error, term()}
  def workspace_for_scope(%Scope{} = scope) do
    with :ok <- demo_enabled_result(),
         :ok <- single_node_result(),
         :ok <- authorize_scope(scope),
         %User{} = user <- scope.user,
         %Workspace{} = workspace <-
           Repo.one(
             from w in Workspace,
               where:
                 w.team_id == ^Scope.team_id!(scope) and w.owner_user_id == ^user.id and
                   w.state == :active
           ) do
      bundle_for(user, workspace)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  @spec demo_team?(Ecto.UUID.t()) :: boolean()
  def demo_team?(team_id) do
    enabled?() and single_node?() and
      Repo.exists?(from w in Workspace, where: w.team_id == ^team_id and w.state == :active)
  end

  @spec mark_step(Scope.t(), String.t() | atom(), map()) ::
          {:ok, Workspace.t()} | {:error, term()}
  def mark_step(%Scope{} = scope, step, artifact_refs \\ %{}) when is_map(artifact_refs) do
    with {:ok, bundle} <- workspace_for_scope(scope), step_key <- normalize_step(step) do
      Repo.transaction(fn ->
        workspace =
          Repo.one!(from w in Workspace, where: w.id == ^bundle.workspace.id, lock: "FOR UPDATE")

        workspace =
          workspace
          |> Ecto.Changeset.change(
            progress: Map.put(workspace.progress || %{}, step_key, artifact_refs)
          )
          |> Repo.update!()

        Audit.record!(scope, "demo.workspace.step_completed",
          aggregate: {:demo_workspace, workspace.id},
          payload: %{step: step_key, artifact_refs: artifact_refs}
        )

        Outbox.emit!("demo_workspace.step_completed.v1",
          aggregate: {:demo_workspace, workspace.id},
          team_id: workspace.team_id,
          correlation_id: scope.correlation_id,
          payload: %{step: step_key}
        )

        workspace
      end)
    end
  end

  @doc """
  Arms one simulated provider rejection on the workspace's fake ERP
  instance (BC-US-166 failure/remediation story).

  The next draft-creation write is rejected once with a provider error of
  the chosen `kind`, exercising the real durable-operation failure path
  and the matching operations-inbox remediation (SPEC §22.9.1 classes):

    * `:validation` (default) — user-fixable; dead-letters for manual retry;
    * `:transient` — self-healing; the retry policy replays automatically;
    * `:authorization` — operator-only; the operation blocks and the ERP
      connection is marked action-required until an admin revalidates it;
    * `:terminal` — non-retryable from the inbox; escalate with the bundle.

  This touches only the demo provider's fault injection — never a domain
  command — and records an audit fact so the induced failure has a
  visible cause.
  """
  @spec simulate_provider_failure(Scope.t(), atom()) :: :ok | {:error, term()}
  def simulate_provider_failure(%Scope{} = scope, kind \\ :validation) do
    with {:ok, response} <- drill_response(kind),
         {:ok, bundle} <- workspace_for_scope(scope),
         {:ok, context} <- FakeERPInstances.context_for(bundle.connection) do
      :ok = BillingCore.ERP.FakeERP.inject_failure(context.fake_server, :create_draft, response)

      Audit.record!(scope, "demo.provider_failure_injected",
        aggregate: {:demo_workspace, bundle.workspace.id},
        payload: %{operation: "create_draft", mode: "one_shot", kind: kind}
      )

      :ok
    end
  end

  defp drill_response(:validation),
    do: {:ok, {:error, {:validation, %{field: "simulated_demo_outage"}}}}

  defp drill_response(:transient),
    do: {:ok, {:error, {:provider_failure, %{status: 502, detail: "simulated_demo_blip"}}}}

  defp drill_response(:authorization),
    do: {:ok, {:error, {:authorization, %{detail: "simulated_demo_revoked_grant"}}}}

  # The adapter contract classifies unsupported capabilities as terminal —
  # the one provider answer no amount of retrying can change.
  defp drill_response(:terminal),
    do: {:ok, {:error, {:unsupported_capability, :simulated_demo_defect}}}

  defp drill_response(_kind), do: {:error, :unknown_drill}

  @spec reset_workspace(User.t()) :: {:ok, bundle()} | {:error, term()}
  def reset_workspace(%User{} = user) do
    with :ok <- public_user_allowed(user),
         {:ok, {next_workspace, old_connection_id}} <-
           with_advisory_lock(user.id, fn -> reset_phase_a_locked!(user) end),
         :ok <- stop_old_provider(old_connection_id) do
      activate_workspace(user, next_workspace.id)
    end
  end

  # Phase A has no process startup. Concurrent callers converge through the
  # owner advisory lock and the partial uniqueness constraint.
  defp provision_phase_a(%User{} = user, predecessor_workspace_id) do
    with_advisory_lock(user.id, fn ->
      provision_phase_a_locked!(user, predecessor_workspace_id)
    end)
  end

  defp provision_phase_a_locked!(%User{} = user, predecessor_workspace_id) do
    case Repo.one(resumable_workspace_query(user.id)) do
      %Workspace{} = workspace ->
        workspace

      nil ->
        generation = next_generation!(user.id)

        with {:ok, created} <-
               Orgs.create_organization(demo_organization_attrs(user, generation), user),
             {:ok, _} <- Orgs.change_team_roles(created.team_membership, @demo_roles),
             {:ok, scope} <- Orgs.resolve_scope(user, created.organization.id, created.team.id),
             {:ok, workspace} <-
               Repo.insert(new_workspace(created, user, generation, predecessor_workspace_id)),
             {:ok, connection} <-
               ERP.create_connection(scope, %{
                 provider: "fake",
                 secret_reference: "demo:#{workspace.id}"
               }),
             {:ok, _} <-
               Repo.insert(%FakeERPInstance{
                 team_id: created.team.id,
                 workspace_id: workspace.id,
                 erp_connection_id: connection.id,
                 state: :active
               }) do
          workspace
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  # Phase B starts only against already committed rows. Failed validation does
  # not delete or mutate the provisioning generation, so resume can retry it.
  defp activate_workspace(%User{} = user, workspace_id) do
    case connection_for_workspace(workspace_id) do
      nil ->
        {:error, :not_found}

      %Connection{} = connection ->
        was_running? =
          match?({:ok, _}, BillingCore.ERP.FakeERP.InstanceSupervisor.fetch(connection.id))

        case with_advisory_lock(user.id, fn -> activate_workspace_locked!(user, workspace_id) end) do
          {:ok, bundle} ->
            {:ok, bundle}

          {:error, reason} ->
            if not was_running?,
              do: _ = BillingCore.ERP.FakeERP.InstanceSupervisor.stop(connection.id)

            {:error, reason}
        end
    end
  end

  defp activate_workspace_locked!(%User{} = user, workspace_id) do
    workspace =
      Repo.one!(
        from w in Workspace,
          where: w.id == ^workspace_id and w.owner_user_id == ^user.id,
          lock: "FOR UPDATE"
      )

    case workspace.state do
      :active ->
        case bundle_for(user, workspace) do
          {:ok, bundle} -> bundle
          {:error, reason} -> Repo.rollback(reason)
        end

      :provisioning ->
        with {:ok, base} <- base_bundle_for(user, workspace),
             {:ok, _} <- FakeERPInstances.context_for(base.connection),
             {:ok, connection} <- ERP.validate_connection(base.scope, base.connection),
             :ok <- ensure_connection_active(connection) do
          workspace = workspace |> Ecto.Changeset.change(state: :active) |> Repo.update!()
          record_started!(base.scope, workspace)
          %{base | workspace: workspace, connection: connection}
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      _ ->
        Repo.rollback(:not_resumable)
    end
  end

  defp bundle_for(user, %Workspace{state: :active} = workspace) do
    with {:ok, base} <- base_bundle_for(user, workspace),
         {:ok, _} <- FakeERPInstances.context_for(base.connection) do
      {:ok, Map.put(base, :workspace, workspace)}
    end
  end

  defp bundle_for(_, _), do: {:error, :not_found}

  defp base_bundle_for(%User{} = user, %Workspace{} = workspace) do
    with %Organization{} = organization <- Repo.get(Organization, workspace.organization_id),
         %Team{} = team <- Repo.get(Team, workspace.team_id),
         {:ok, scope} <- Orgs.resolve_scope(user, organization.id, team.id),
         %FakeERPInstance{} = instance <-
           Repo.one(
             from i in FakeERPInstance,
               where:
                 i.workspace_id == ^workspace.id and i.team_id == ^workspace.team_id and
                   i.state == :active
           ),
         %Connection{} = connection <- Repo.get(Connection, instance.erp_connection_id),
         :ok <- ensure_connection_team(connection, workspace.team_id) do
      {:ok,
       %{
         workspace: workspace,
         organization: organization,
         team: team,
         scope: scope,
         connection: connection
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  defp reset_phase_a_locked!(%User{} = user) do
    with %Workspace{} = workspace <- Repo.one(active_workspace_query(user.id)),
         {:ok, bundle} <- bundle_for(user, workspace) do
      locked = Repo.one!(from w in Workspace, where: w.id == ^workspace.id, lock: "FOR UPDATE")

      instance =
        Repo.one!(
          from i in FakeERPInstance,
            where: i.workspace_id == ^locked.id and i.state == :active,
            lock: "FOR UPDATE"
        )

      archived =
        locked
        |> Ecto.Changeset.change(state: :archived, reset_at: DateTime.utc_now())
        |> Repo.update!()

      _ =
        instance
        |> Ecto.Changeset.change(state: :archived)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update!()

      Audit.record!(bundle.scope, "demo.workspace.archived",
        aggregate: {:demo_workspace, archived.id},
        payload: %{generation: archived.generation, reason: "reset"}
      )

      Outbox.emit!("demo_workspace.archived.v1",
        aggregate: {:demo_workspace, archived.id},
        team_id: archived.team_id,
        correlation_id: bundle.scope.correlation_id,
        payload: %{generation: archived.generation, reason: "reset"}
      )

      case remove_owner_membership(bundle) do
        {:ok, _} ->
          {provision_phase_a_locked!(user, archived.id), instance.erp_connection_id}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp new_workspace(created, user, generation, predecessor_id) do
    %Workspace{
      team_id: created.team.id,
      organization_id: created.organization.id,
      owner_user_id: user.id,
      scenario_version: @scenario_version,
      generation: generation,
      state: :provisioning,
      seed_key: seed_key(user.id, generation),
      progress: %{},
      started_at: DateTime.utc_now(),
      predecessor_workspace_id: predecessor_id
    }
  end

  defp connection_for_workspace(workspace_id) do
    Repo.one(
      from i in FakeERPInstance,
        join: c in Connection,
        on: c.id == i.erp_connection_id,
        where: i.workspace_id == ^workspace_id and i.state == :active,
        select: c
    )
  end

  defp remove_owner_membership(%{team: team, scope: scope}) do
    case Repo.one(
           from m in TeamMembership,
             where: m.team_id == ^team.id and m.user_id == ^scope.user.id and m.status == :active
         ) do
      nil -> {:error, :membership_not_found}
      membership -> Orgs.remove_team_member(membership, scope)
    end
  end

  defp stop_old_provider(id) do
    case BillingCore.ERP.FakeERP.InstanceSupervisor.stop(id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp record_started!(scope, workspace) do
    Audit.record!(scope, "demo.workspace.started",
      aggregate: {:demo_workspace, workspace.id},
      payload: %{scenario_version: workspace.scenario_version, generation: workspace.generation}
    )

    Outbox.emit!("demo_workspace.started.v1",
      aggregate: {:demo_workspace, workspace.id},
      team_id: workspace.team_id,
      correlation_id: scope.correlation_id,
      payload: %{scenario_version: workspace.scenario_version, generation: workspace.generation}
    )
  end

  defp active_workspace_query(user_id),
    do:
      from(w in Workspace,
        where: w.owner_user_id == ^user_id and w.state == :active,
        order_by: [desc: w.generation],
        limit: 1
      )

  defp resumable_workspace_query(user_id),
    do:
      from(w in Workspace,
        where: w.owner_user_id == ^user_id and w.state in ^@resumable_states,
        order_by: [desc: w.generation],
        limit: 1
      )

  defp next_generation!(user_id),
    do:
      (Repo.one(
         from w in Workspace, where: w.owner_user_id == ^user_id, select: max(w.generation)
       ) || 0) + 1

  defp demo_organization_attrs(user, generation) do
    fragment = user.id |> String.replace("-", "") |> String.slice(0, 8)

    %{
      name: "Revryn Demo #{fragment} #{generation}",
      slug: "revryn-demo-#{fragment}-#{generation}",
      team_name: "Northstar Studio",
      team_slug: "northstar-studio",
      legal_name: "Northstar Studio ApS",
      base_currency: "DKK",
      time_zone: "Europe/Copenhagen",
      locale: "en-DK"
    }
  end

  defp seed_key(user_id, generation),
    do:
      Canonical.hash(%{
        scenario_version: @scenario_version,
        owner_user_id: user_id,
        generation: generation
      })

  defp with_advisory_lock(user_id, fun) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["demo-workspace:#{user_id}"])
        fun.()
      end)

    case result do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp public_user_allowed(%User{status: :active}),
    do: with(:ok <- demo_enabled_result(), do: single_node_result())

  defp public_user_allowed(%User{}), do: {:error, :unauthorized}
  defp demo_enabled_result, do: if(enabled?(), do: :ok, else: {:error, :demo_disabled})

  defp single_node_result,
    do: if(single_node?(), do: :ok, else: {:error, :demo_requires_single_node})

  defp authorize_scope(%Scope{} = scope),
    do:
      if(Scope.team_scoped?(scope) and Scope.has_team_role?(scope, @demo_roles),
        do: :ok,
        else: {:error, :unauthorized}
      )

  defp ensure_connection_team(%Connection{team_id: id}, id), do: :ok
  defp ensure_connection_team(_, _), do: {:error, :unauthorized}
  defp ensure_connection_active(%Connection{status: "active"}), do: :ok
  defp ensure_connection_active(_), do: {:error, :demo_connection_unusable}
  defp normalize_step(step) when is_atom(step), do: Atom.to_string(step)
  defp normalize_step(step) when is_binary(step) and byte_size(step) in 1..80, do: step

  defp normalize_step(_),
    do: raise(ArgumentError, "demo step must be a non-empty short string or atom")
end
