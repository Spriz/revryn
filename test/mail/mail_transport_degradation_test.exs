defmodule BillingCore.MailCrashStubAdapter do
  @moduledoc """
  Test stand-in reproducing the production failure this suite guards
  against: `Swoosh.Adapters.Local` without its storage process exits with
  `:noproc` from inside `deliver/2` (releases set `config :swoosh,
  local: false`).
  """

  use Swoosh.Adapter

  @impl true
  def deliver(%Swoosh.Email{}, _config), do: exit({:noproc, {GenServer, :call, []}})
end

defmodule BillingCore.MailTransportDegradationTest do
  @moduledoc """
  Mail delivery is best-effort around the invitation flow: a missing or
  crashing transport must degrade to `delivery: :failed` with the
  invitation (and its copyable link) intact — never take down the caller.
  Regression coverage for the release-mode LiveView crash found by the
  Playwright E2E suite.
  """

  use BillingCore.DataCase, async: false

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.Orgs

  setup do
    %{organization: organization, team: team} = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(organization, admin, [:organization_admin])
    {:ok, scope} = Orgs.resolve_scope(admin, organization.id)

    previous = Application.get_env(:billing_core, BillingCore.Mailer)
    on_exit(fn -> Application.put_env(:billing_core, BillingCore.Mailer, previous) end)

    %{team: team, admin_scope: scope}
  end

  defp invite!(scope, team) do
    Orgs.invite_member(scope, %{
      email: "degraded-#{System.unique_integer([:positive])}@example.com",
      organization_roles: ["organization_member"],
      team_id: team.id,
      team_roles: ["auditor"],
      accept_url_fun: fn t -> "https://revryn.example/invitations/accept/#{t}" end
    })
  end

  test "the NoTransport adapter reports delivery :failed, invitation intact",
       %{team: team, admin_scope: scope} do
    Application.put_env(:billing_core, BillingCore.Mailer,
      adapter: BillingCore.Mailer.NoTransport
    )

    assert {:ok, %{invitation: invitation, token: token, delivery: :failed}} =
             invite!(scope, team)

    assert invitation.id
    assert is_binary(token)
  end

  test "a transport that exits mid-delivery degrades to :failed instead of crashing the caller",
       %{team: team, admin_scope: scope} do
    Application.put_env(:billing_core, BillingCore.Mailer,
      adapter: BillingCore.MailCrashStubAdapter
    )

    assert {:ok, %{invitation: invitation, token: token, delivery: :failed}} =
             invite!(scope, team)

    assert invitation.id
    assert is_binary(token)
  end
end
