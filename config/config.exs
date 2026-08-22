# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Guided mock-ERP workspaces are opt-in outside development/test. The runtime
# override is `REVRYN_DEMO_ERP_ENABLED=true` (SPEC §34, BC-TASK-105).
config :billing_core, :demo_erp_enabled, false

config :billing_core,
  ecto_repos: [BillingCore.Repo],
  generators: [timestamp_type: :utc_datetime]

# Pin the connection search_path (and unprefixed migration DDL) to public.
# PostgreSQL's default search_path starts with "$user": once a schema named
# after the database role exists (the official image's role is `billing`,
# colliding with our `billing` schema), unqualified references — notably
# Ecto's schema_migrations bookkeeping — silently resolve into that schema.
# Readiness then reports every migration pending forever and a restart
# would try to re-run the whole chain. Application schemas always carry
# explicit prefixes; pinning removes the role-name dependence entirely.
config :billing_core, BillingCore.Repo,
  parameters: [search_path: "public"],
  migration_default_prefix: "public"

# Configure the endpoint

# Durable work runs on Oban OSS backed by PostgreSQL (SPEC ADR-024).
config :billing_core, Oban,
  engine: Oban.Engines.Basic,
  repo: BillingCore.Repo,
  queues: [
    billing: 10,
    erp: 10,
    reconciliation: 5,
    usage: 10,
    email: 5,
    maintenance: 2,
    outbox: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       # Daily billing-run tick (SPEC §18.1); fans out per-team jobs.
       {"0 2 * * *", BillingCore.Billing.RunWorker},
       # ERP polling fallback at least every 15 minutes (SPEC §17.12).
       {"*/15 * * * *", BillingCore.ERP.PollAllWorker},
       # Usage partition maintenance, two months ahead (SPEC §13.1).
       {"0 3 * * *", BillingCore.Usage.PartitionWorker},
       # SPEC §20: nightly operational-retention enforcement (allowlisted
       # machinery tables only; financial evidence is never pruned by jobs).
       {"30 2 * * *", BillingCore.AuditExport.RetentionWorker}
     ]}
  ]

config :billing_core, BillingCoreWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BillingCoreWeb.ErrorHTML, json: BillingCoreWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BillingCore.PubSub,
  live_view: [signing_salt: "dUR3JCcj"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :billing_core, BillingCore.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  billing_core: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  billing_core: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Team time zones (Europe/Copenhagen default) need real IANA rules.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# WebAuthn relying-party identity (SPEC §19.2, BC-US-145). Origin and RP ID
# are deployment configuration and are validated exactly; override per
# environment (config/runtime.exs in prod).
config :billing_core, :webauthn,
  origin: "http://localhost:4000",
  rp_id: "localhost"
