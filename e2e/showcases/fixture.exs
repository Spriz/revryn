# Integrated-showcase fixture (BC-TASK-094): a real user with a guided demo
# workspace — its team carries a validated FakeERP connection — plus a
# bearer session for the showcase's GraphQL adapter. Prints ONE JSON line.
Application.put_env(:billing_core, :metrics_port, 19_569)
Application.put_env(:billing_core, :demo_erp_enabled, true)
{:ok, _} = Application.ensure_all_started(:billing_core)

alias BillingCore.{Demo, Identity}

suffix = System.unique_integer([:positive])
{:ok, user} = Identity.register_user("showcase-#{suffix}@example.com")
{:ok, bundle} = Demo.start_workspace(user)
{token, _session} = Identity.create_session(user)

IO.puts(
  Jason.encode!(%{
    token: token,
    team_id: bundle.team.id,
    connection_id: bundle.connection.id
  })
)
