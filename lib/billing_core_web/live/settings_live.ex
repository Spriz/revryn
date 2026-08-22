defmodule BillingCoreWeb.SettingsLive do
  @moduledoc """
  Team settings: ERP connection management with preflight validation
  (BC-US-003/004) and the team's configuration snapshot.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.AuditExport.Retention
  alias BillingCore.ERP
  alias BillingCore.Orgs
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:settings} />

      <.header>
        Settings
        <:subtitle>{@team.legal_name}</:subtitle>
      </.header>

      <div class="grid gap-6 lg:grid-cols-2">
        <section class="rounded-lg border border-base-300 p-4" id="erp-connection-settings">
          <h2 class="mb-2 font-semibold">ERP connection</h2>

          <div :if={@connection} class="space-y-3">
            <p class="text-sm">
              Provider <span class="font-medium">{@connection.provider}</span>
              <.state_badge state={@connection.status} class="ml-1" id="connection-status-badge" />
            </p>
            <p class="text-sm opacity-70">
              Secret reference: <span class="font-mono">{@connection.secret_reference}</span>
              — credentials live only in the secret store, never in the database.
            </p>
            <p :if={@connection.last_validated_at} class="text-sm opacity-70">
              Last validated {format_dt(@connection.last_validated_at)}
            </p>

            <.button
              id="validate-connection"
              variant="primary"
              phx-click="validate"
              phx-disable-with="Validating…"
            >
              Validate connection
            </.button>

            <div :if={@preflight_checks != []} id="preflight-checks" class="mt-2">
              <h3 class="text-sm font-semibold">Preflight checks</h3>
              <ul class="mt-1 space-y-1 text-sm">
                <li :for={check <- @preflight_checks} class="flex items-center gap-2">
                  <.state_badge state={check["status"]} />
                  <span class="font-medium">{check["check"]}</span>
                  <span class="opacity-70">{check["detail"]}</span>
                </li>
              </ul>
            </div>
          </div>

          <div :if={!@connection}>
            <p class="mb-3 text-sm opacity-70">
              Connect this team to e-conomic. Guided sample books are created only from Revryn's
              isolated demo flow and never share this connection.
            </p>
            <.form for={@connection_form} id="new-connection-form" phx-submit="create_connection">
              <.input
                field={@connection_form[:provider]}
                type="hidden"
                value="economic"
              />
              <div class="mb-4 rounded-lg border border-base-300 px-3 py-2 text-sm">
                <span class="font-medium">Provider</span>
                <span class="ml-2 opacity-70">e-conomic</span>
              </div>
              <.input
                field={@connection_form[:secret_reference]}
                type="text"
                label="Secret reference"
                placeholder="e.g. ECONOMIC_TOKENS_TEAM_A"
                required
              />
              <.input
                field={@connection_form[:external_agreement_id]}
                type="text"
                label="Agreement ID (optional)"
              />
              <.button variant="primary" class="mt-2" phx-disable-with="Creating…">
                Create connection
              </.button>
            </.form>
          </div>
        </section>

        <section class="rounded-lg border border-base-300 p-4" id="team-settings-card">
          <h2 class="mb-2 font-semibold">Team</h2>
          <dl class="space-y-1 text-sm">
            <div class="flex justify-between">
              <dt class="opacity-60">Name</dt>
              <dd>{@team.name}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="opacity-60">Slug</dt>
              <dd class="font-mono">{@team.slug}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="opacity-60">Legal name</dt>
              <dd>{@team.legal_name}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="opacity-60">Base currency</dt>
              <dd>{@team.base_currency}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="opacity-60">Time zone</dt>
              <dd>{@team.time_zone}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="opacity-60">Locale</dt>
              <dd>{@team.locale}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="opacity-60">Settings version</dt>
              <dd>v{@team.settings_version}</dd>
            </div>
          </dl>
          <div :if={@settings_snapshot} class="mt-3">
            <.trace
              id="team-settings-snapshot"
              trace={@settings_snapshot.settings}
              label="Current settings snapshot"
            />
          </div>
        </section>

        <section class="rounded-lg border border-base-300 p-4" id="retention-settings-card">
          <h2 class="mb-2 font-semibold">Data retention</h2>
          <p class="text-sm opacity-70">
            Raw usage events already consumed by an invoice freeze can be pruned after a
            team-configured window (minimum {Retention.raw_usage_min_days()} days — dispute and
            audit needs outrank storage). Frozen calculation traces are retained as financial
            evidence regardless. Leave blank to retain raw usage indefinitely.
          </p>
          <.form
            for={@retention_form}
            id="retention-settings-form"
            phx-submit="update_retention"
            class="mt-3 flex items-end gap-3"
          >
            <.input
              field={@retention_form[:raw_usage_retention_days]}
              type="number"
              label="Raw-usage retention (days)"
              min={Retention.raw_usage_min_days()}
            />
            <.button variant="primary" phx-disable-with="Saving…">Save</.button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    snapshot = Orgs.current_team_settings(socket.assigns.team)

    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       connection_form: to_form(%{"provider" => "economic"}, as: "connection"),
       settings_snapshot: snapshot,
       retention_form: retention_form(snapshot)
     )
     |> load_connection()}
  end

  defp retention_form(snapshot) do
    configured = snapshot && snapshot.settings["raw_usage_retention_days"]

    to_form(%{"raw_usage_retention_days" => configured && to_string(configured)},
      as: "retention"
    )
  end

  def handle_event("update_retention", %{"retention" => params}, socket) do
    scope = socket.assigns.scope
    current = Orgs.current_team_settings(socket.assigns.team)
    settings = (current && current.settings) || %{}

    settings =
      case Integer.parse(params["raw_usage_retention_days"] || "") do
        {days, ""} when days > 0 ->
          Map.put(
            settings,
            "raw_usage_retention_days",
            max(days, Retention.raw_usage_min_days())
          )

        _blank_or_invalid ->
          Map.delete(settings, "raw_usage_retention_days")
      end

    {:ok, _version} = Orgs.update_team_settings(socket.assigns.team, settings, scope)
    snapshot = Orgs.current_team_settings(socket.assigns.team)

    {:noreply,
     socket
     |> put_flash(:info, "Retention settings saved.")
     |> assign(settings_snapshot: snapshot, retention_form: retention_form(snapshot))}
  end

  def handle_event("create_connection", %{"connection" => params}, socket) do
    attrs = %{
      provider: "economic",
      secret_reference: params["secret_reference"],
      external_agreement_id: presence(params["external_agreement_id"])
    }

    case ERP.create_connection(socket.assigns.scope, attrs) do
      {:ok, connection} ->
        {:noreply,
         socket
         |> put_flash(:info, "Connection created — validate it before synchronizing.")
         |> assign(connection: connection)
         |> load_connection()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  def handle_event("validate", _params, socket) do
    case ERP.validate_connection(socket.assigns.scope, socket.assigns.connection) do
      {:ok, connection} ->
        message =
          if connection.status == "active" do
            "Connection validated — all checks passed."
          else
            "Validation found failing checks — the connection needs attention."
          end

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign(connection: connection)
         |> load_connection()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  rescue
    error ->
      {:noreply,
       put_flash(
         socket,
         :error,
         "Validation failed: #{Exception.message(error)}"
       )}
  end

  defp load_connection(socket) do
    connection =
      case ERP.get_connection(socket.assigns.scope) do
        {:ok, connection} -> connection
        {:error, :not_found} -> nil
      end

    preflight_checks =
      case connection do
        %{preflight_result: %{"checks" => checks}} when is_list(checks) -> checks
        _other -> []
      end

    assign(socket, connection: connection, preflight_checks: preflight_checks)
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
