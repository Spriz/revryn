defmodule BillingCoreWeb.Router do
  use BillingCoreWeb, :router

  import BillingCoreWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BillingCoreWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :graphql do
    plug :accepts, ["json"]
    plug BillingCoreWeb.GraphQL.Context
  end

  # Public GraphQL application API (SPEC §14, INV-017).
  scope "/graphql" do
    pipe_through :graphql

    forward "/", Absinthe.Plug,
      schema: BillingCoreWeb.GraphQL.Schema,
      json_codec: Jason,
      analyze_complexity: true,
      max_complexity: 250
  end

  # Protocol/infrastructure endpoints (SPEC §14.1): health and provider
  # webhooks only — application resources are GraphQL-only (INV-017).
  scope "/health", BillingCoreWeb do
    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/webhooks", BillingCoreWeb do
    post "/erp/:endpoint_token", ErpWebhookController, :receive
  end

  scope "/", BillingCoreWeb do
    pipe_through :browser

    # Passkey-first authentication (SPEC §19.2, BC-US-145/146).
    live "/sign-in", AuthLive.SignIn, :new
    live "/register", AuthLive.Register, :new
    post "/session", SessionController, :create
    delete "/session", SessionController, :delete

    live_session :authenticated,
      on_mount: [{BillingCoreWeb.UserAuth, :ensure_authenticated}] do
      live "/", DashboardLive, :index
      live "/start", FirstRunLive, :index
      live "/security", AuthLive.Security, :index
      live "/invitations/:token", Features.Organization.AcceptInvitationLive, :accept

      # Team-scoped product UI (BC-US-120). Each of these LiveViews declares
      # the BillingCoreWeb.TeamScope on_mount hook, which resolves the
      # authorization scope from :team_id (SPEC §13.4).
      live "/teams/:team_id", TeamLive.Overview, :show
      live "/teams/:team_id/demo", DemoLive.Show, :show
      live "/teams/:team_id/customers", CustomerLive.Index, :index
      live "/teams/:team_id/customers/:id", CustomerLive.Show, :show
      live "/teams/:team_id/catalog", CatalogLive.Index, :index
      live "/teams/:team_id/catalog/plan-versions/:id", CatalogLive.PlanVersion, :show
      live "/teams/:team_id/subscriptions", SubscriptionLive.Index, :index
      live "/teams/:team_id/subscriptions/:id", SubscriptionLive.Show, :show
      live "/teams/:team_id/billing-runs", BillingRunLive.Index, :index
      live "/teams/:team_id/billing-runs/:id", BillingRunLive.Show, :show
      live "/teams/:team_id/credit-closes", CreditCloses.IndexLive, :index
      live "/teams/:team_id/credit-closes/:id", CreditCloses.ShowLive, :show
      live "/teams/:team_id/invoices/:intent_id", IntentLive, :show
      live "/teams/:team_id/operations", OperationsLive, :index
      live "/teams/:team_id/settings", SettingsLive, :index
      live "/teams/:team_id/members", Features.Organization.MembersLive, :index
    end
  end

  # Browser file download for immutable close evidence — same scope
  # resolution and domain command as the LiveView surface (not an API;
  # INV-017 keeps application resources GraphQL-only).
  scope "/", BillingCoreWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/teams/:team_id/credit-closes/:id/report/:evidence_type",
        CreditCloses.ReportController,
        :download
  end

  # Operational dashboard for platform administrators — available in every
  # environment behind authentication (BC-US-120 operability).
  import Phoenix.LiveDashboard.Router

  scope "/admin" do
    pipe_through [:browser, :require_authenticated_user, :require_platform_admin]

    live_dashboard "/dashboard",
      metrics: BillingCoreWeb.Telemetry,
      live_session_name: :admin_live_dashboard
  end

  # Other scopes may use custom stacks.
  # scope "/api", BillingCoreWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:billing_core, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BillingCoreWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Gate for /admin: authenticated platform administrators only (never a
  # bypass of team membership checks — the dashboard exposes runtime
  # internals, not team data).
  defp require_platform_admin(conn, _opts) do
    case conn.assigns[:current_user] do
      %{platform_admin: true} ->
        conn

      _other ->
        conn
        |> put_flash(:error, "Platform administrator access required.")
        |> redirect(to: "/")
        |> halt()
    end
  end
end
