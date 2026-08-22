# CLI/MCP certification fixture (BC-TASK-100). Creates a real user,
# workspace, customer, and credit account, then prints ONE JSON line with
# the bearer token and ids. Runs under
# `mix run --no-start e2e/cli/fixture.exs` alongside the dev server
# (the metrics exporter moves off the server's port), or
# `bin/billing_core eval "$(cat e2e/cli/fixture.exs)"` against a release.
Application.put_env(:billing_core, :metrics_port, 19_568)

# Never bind the web listener from the fixture: releases export
# PHX_SERVER=true via rel/env.sh.eex, and the real server already holds
# the port.
endpoint_config = Application.get_env(:billing_core, BillingCoreWeb.Endpoint, [])

Application.put_env(
  :billing_core,
  BillingCoreWeb.Endpoint,
  Keyword.put(endpoint_config, :server, false)
)

{:ok, _} = Application.ensure_all_started(:billing_core)

alias BillingCore.{Contracts, Credits, Identity, Orgs}

suffix = System.unique_integer([:positive])

{:ok, user} = Identity.register_user("cli-cert-#{suffix}@example.com")

{:ok, %{organization: organization, team: team}} =
  Orgs.create_organization(
    %{name: "CLI Cert #{suffix}", team_name: "Finance", base_currency: "DKK"},
    user
  )

# The workspace creator starts as team_admin; certification also drives
# the finance surfaces.
membership =
  BillingCore.Repo.get_by!(BillingCore.Orgs.TeamMembership, team_id: team.id, user_id: user.id)

{:ok, _} =
  Orgs.change_team_roles(membership, [:team_admin, :billing_admin, :finance_operator])

{:ok, scope} = Orgs.resolve_scope(user, organization.id, team.id)

{:ok, %{customer: customer}} =
  Contracts.upsert_customer(scope, %{
    external_id: "cli-cust-#{suffix}",
    legal_name: "Nordhavn Certifikat ApS",
    email: "faktura@nordhavn-cert.example",
    country: "DK"
  })

# organization-level commercial account projected to the team
account =
  (fn ->
     {:ok, account} =
       Orgs.create_account(
         organization,
         %{external_id: "cli-acct-#{suffix}", display_name: "Cert account #{suffix}"},
         scope
       )

     {:ok, _} = Orgs.project_account_to_team(account, team, customer.id, scope)
     account
   end).()

{:ok, credit_account} = Credits.get_or_create_account(scope, account.id, "DKK")

{:ok, _grant} =
  Credits.grant_credit(scope, %{
    credit_account_id: credit_account.id,
    origin_type: "goodwill",
    amount_minor: 12_500,
    currency: "DKK",
    idempotency_key: "cli-cert-grant-#{suffix}"
  })

{token, _session} = Identity.create_session(user)

IO.puts(
  Jason.encode!(%{
    token: token,
    team_id: team.id,
    customer_id: customer.id,
    credit_account_id: credit_account.id
  })
)
