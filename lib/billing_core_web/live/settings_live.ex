defmodule BillingCoreWeb.SettingsLive do
  @moduledoc """
  Team settings: ERP connection management with preflight validation
  (BC-US-003/004) and the team's configuration snapshot.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

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
              Connect this team to its accounting system. One connection per team.
            </p>
            <.form for={@connection_form} id="new-connection-form" phx-submit="create_connection">
              <.input
                field={@connection_form[:provider]}
                type="select"
                label="Provider"
                options={[{"e-conomic", "economic"}, {"Fake (testing)", "fake"}]}
              />
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
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Settings",
       connection_form: to_form(%{"provider" => "economic"}, as: "connection"),
       settings_snapshot: Orgs.current_team_settings(socket.assigns.team)
     )
     |> load_connection()}
  end

  def handle_event("create_connection", %{"connection" => params}, socket) do
    attrs = %{
      provider: params["provider"],
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
