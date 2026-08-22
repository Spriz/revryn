defmodule BillingCore.AuditTest do
  @moduledoc """
  Append-only audit recording (SPEC §13.3 `audit_log`, INV-028): actor
  attribution for system/user/service principals, scope-derived defaults
  and their explicit overrides, aggregate references, and the database-level
  append-only guarantee.
  """

  use BillingCore.DataCase, async: true

  import BillingCore.IdentityFixtures

  alias BillingCore.{Audit, Scope}
  alias BillingCore.Audit.Entry

  describe "record!/3 actor attribution" do
    test "system actor carries no principal, scope, or correlation" do
      entry = Audit.record!(:system, "billing.run.started")

      assert entry.actor_type == "system"
      assert entry.actor_id == nil
      assert entry.organization_id == nil
      assert entry.team_id == nil
      assert entry.correlation_id == nil
      assert entry.aggregate_type == nil
      assert entry.aggregate_id == nil
      assert entry.payload == %{}
      assert %DateTime{} = entry.occurred_at

      assert Repo.get!(Entry, entry.id).event_type == "billing.run.started"
    end

    test "a user scope contributes actor id, org/team, and correlation id" do
      user = user_fixture()
      org_id = Ecto.UUID.generate()
      team_id = Ecto.UUID.generate()
      correlation_id = Ecto.UUID.generate()

      scope = %Scope{
        principal_type: :user,
        user: user,
        organization: %{id: org_id},
        team: %{id: team_id},
        correlation_id: correlation_id
      }

      entry = Audit.record!(scope, "invoice_intent.frozen")

      assert entry.actor_type == "user"
      assert entry.actor_id == to_string(user.id)
      assert entry.organization_id == org_id
      assert entry.team_id == team_id
      assert entry.correlation_id == correlation_id
    end

    test "a service scope is attributed to its service credential" do
      credential_id = Ecto.UUID.generate()

      scope = %Scope{
        principal_type: :service,
        service_credential: %{id: credential_id}
      }

      entry = Audit.record!(scope, "erp.document.booked")

      assert entry.actor_type == "service"
      assert entry.actor_id == credential_id
    end

    test "a scope without a resolved principal or org/team records nils" do
      scope = %Scope{principal_type: :user}

      entry = Audit.record!(scope, "identity.session.revoked")

      assert entry.actor_type == "user"
      assert entry.actor_id == nil
      assert entry.organization_id == nil
      assert entry.team_id == nil
      assert entry.correlation_id == nil
    end
  end

  describe "record!/3 options" do
    test "aggregate, payload, and causation are recorded" do
      aggregate_id = Ecto.UUID.generate()
      causation_id = Ecto.UUID.generate()

      entry =
        Audit.record!(:system, "invoice_intent.superseded",
          aggregate: {:invoice_intent, aggregate_id},
          causation_id: causation_id,
          payload: %{"reason" => "correction"}
        )

      assert entry.aggregate_type == "invoice_intent"
      assert entry.aggregate_id == aggregate_id
      assert entry.causation_id == causation_id
      assert entry.payload == %{"reason" => "correction"}
    end

    test "explicit org/team/correlation options override the scope defaults" do
      user = user_fixture()

      scope = %Scope{
        principal_type: :user,
        user: user,
        organization: %{id: Ecto.UUID.generate()},
        team: %{id: Ecto.UUID.generate()},
        correlation_id: Ecto.UUID.generate()
      }

      org_id = Ecto.UUID.generate()
      team_id = Ecto.UUID.generate()
      correlation_id = Ecto.UUID.generate()

      entry =
        Audit.record!(scope, "orgs.team.archived",
          organization_id: org_id,
          team_id: team_id,
          correlation_id: correlation_id
        )

      assert entry.organization_id == org_id
      assert entry.team_id == team_id
      assert entry.correlation_id == correlation_id
    end
  end

  describe "append-only enforcement (INV-028)" do
    test "the database rejects deleting audit evidence" do
      entry = Audit.record!(:system, "billing.run.started")

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(from e in Entry, where: e.id == ^entry.id)
      end
    end

    test "the database rejects updating audit evidence" do
      entry = Audit.record!(:system, "billing.run.started")

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(
          from(e in Entry, where: e.id == ^entry.id),
          set: [event_type: "tampered"]
        )
      end
    end
  end
end
