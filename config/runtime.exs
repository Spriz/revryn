import Config

case System.get_env("REVRYN_DEMO_ERP_ENABLED") do
  value when value in ["true", "1"] -> config :billing_core, :demo_erp_enabled, true
  value when value in ["false", "0"] -> config :billing_core, :demo_erp_enabled, false
  _unset_or_invalid -> :ok
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/billing_core start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :billing_core, BillingCoreWeb.Endpoint, server: true
end

config :billing_core, BillingCoreWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :billing_core, BillingCoreWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/billing_core_web/router\.ex$"E,
        ~r"lib/billing_core_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # Deployment secrets accept the standard <NAME>_FILE indirection alongside
  # plain environment variables — see BillingCore.Release.read_secret/1.
  read_secret = &BillingCore.Release.read_secret/1

  database_url =
    read_secret.("DATABASE_URL") ||
      raise """
      DATABASE_URL (or DATABASE_URL_FILE) is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :billing_core, BillingCore.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    read_secret.("SECRET_KEY_BASE") ||
      raise """
      SECRET_KEY_BASE (or SECRET_KEY_BASE_FILE) is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :billing_core, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Websocket/LiveView origin allow-list. Unset keeps the framework default
  # (origins must match the configured url). The release-based browser
  # certification harness (SPEC §23.6) sets an explicit http://localhost
  # origin; "false" is for isolated lab environments only.
  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      nil -> true
      "false" -> false
      origins -> String.split(origins, ",", trim: true)
    end

  config :billing_core, BillingCoreWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :billing_core, BillingCoreWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :billing_core, BillingCoreWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # Vendor-neutral SMTP transport (BC-US-147): any standards-compliant
  # relay works with configuration only — no provider HTTP API. TLS modes:
  # "starttls" (default, port 587), "ssl" (implicit TLS, port 465), or
  # "never" (isolated lab relays only).
  if smtp_host = System.get_env("SMTP_HOST") do
    smtp_tls = System.get_env("SMTP_TLS", "starttls")
    smtp_username = System.get_env("SMTP_USERNAME")

    config :billing_core, BillingCore.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_host,
      port: String.to_integer(System.get_env("SMTP_PORT", "587")),
      username: smtp_username,
      password: read_secret.("SMTP_PASSWORD"),
      ssl: smtp_tls == "ssl",
      tls: if(smtp_tls == "starttls", do: :always, else: :never),
      tls_options: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(smtp_host),
        depth: 3
      ],
      auth: if(smtp_username, do: :always, else: :never),
      retries: 1
  end

  config :billing_core, :mail,
    from: System.get_env("MAIL_FROM") || "no-reply@#{host}",
    reply_to: System.get_env("MAIL_REPLY_TO")
end

# Restore validation mode (SPEC §23.9, §24.8): hard-disables real ERP writes
# while a restored deployment is being verified. Workers refuse provider
# writes when set.
if System.get_env("RESTORE_VALIDATION_MODE") in ~w(true 1) do
  config :billing_core, :erp_writes_disabled, true
end

# WebAuthn relying-party configuration must match the public URL in
# production (SPEC §19.2).
if config_env() == :prod do
  read_secret = &BillingCore.Release.read_secret/1

  config :billing_core, :webauthn,
    origin:
      System.get_env("WEBAUTHN_ORIGIN") ||
        "https://#{System.get_env("PHX_HOST") || "example.com"}",
    rp_id: System.get_env("WEBAUTHN_RP_ID") || System.get_env("PHX_HOST") || "example.com"

  if key = read_secret.("CREDENTIAL_CIPHER_KEY") do
    config :billing_core, :credential_cipher_key, key
  end
end
