import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :billing_core, BillingCore.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: 55432,
  database: "billing_core_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :billing_core, BillingCoreWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "zL13rNPPLXoegB4+M+nTcXY+e2rUG8/Y0/bw3GsejXp79MJOVvvxU9llT45oMLS6",
  server: false

# In test we don't send emails
config :billing_core, BillingCore.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Oban runs inline/manual in tests.
config :billing_core, Oban, testing: :manual

# TOTP seed envelope-encryption key (SPEC §19.2, BC-US-146): 32 bytes,
# base64-encoded. Test-only value — production must provide the key via
# the CREDENTIAL_CIPHER_KEY environment variable in config/runtime.exs.
config :billing_core, :credential_cipher_key, "TQJ/hpjrRlHW2MrrFsyd+oBBAA8muh9SlwRPRUDn/cw="

# The Prometheus exporter binds a port; keep it off in tests.
config :billing_core, :start_metrics_exporter, false
