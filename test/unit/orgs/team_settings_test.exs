defmodule BillingCore.Orgs.TeamSettingsTest do
  use BillingCore.DataCase, async: true

  alias BillingCore.{Audit, Orgs}
  alias BillingCore.Domain.Canonical
  alias BillingCore.Orgs.TeamSettingsVersion

  import BillingCore.OrgsFixtures

  test "team creation records an initial empty snapshot at version 1" do
    %{team: team} = organization_fixture()

    assert %TeamSettingsVersion{version: 1} = snapshot = Orgs.current_team_settings(team)
    assert snapshot.settings == %{}
    assert snapshot.settings_hash == Canonical.hash(%{})
    assert team.settings_version == 1
  end

  test "update_team_settings/3 bumps the version and stores a hashed immutable snapshot" do
    %{team: team, owner: owner} = organization_fixture()
    settings = %{"invoice_due_days" => 14, "booking_policy" => "accrual"}

    {:ok, scope} = Orgs.resolve_scope(owner, team.organization_id, team.id)

    assert {:ok, %{team: updated_team, settings_version: snapshot}} =
             Orgs.update_team_settings(team, settings, scope)

    assert updated_team.settings_version == 2
    assert snapshot.version == 2
    assert snapshot.settings == settings
    assert snapshot.settings_hash == Canonical.hash(settings)
    assert snapshot.created_by == owner.id

    assert Orgs.current_team_settings(updated_team).id == snapshot.id

    assert [entry] =
             Repo.all(from e in Audit.Entry, where: e.event_type == "orgs.team.settings_updated")

    assert entry.team_id == team.id
    assert entry.payload["version"] == 2
    assert entry.payload["settings_hash"] == snapshot.settings_hash
  end

  test "successive updates append versions 2, 3, ... and history is retained" do
    %{team: team} = organization_fixture()

    {:ok, %{team: team}} = Orgs.update_team_settings(team, %{"a" => 1})
    {:ok, %{team: team}} = Orgs.update_team_settings(team, %{"a" => 2})

    assert team.settings_version == 3

    versions =
      Repo.all(
        from v in TeamSettingsVersion,
          where: v.team_id == ^team.id,
          order_by: [asc: v.version],
          select: {v.version, v.settings}
      )

    assert versions == [{1, %{}}, {2, %{"a" => 1}}, {3, %{"a" => 2}}]
  end

  test "snapshots are immutable at the database level" do
    %{team: team} = organization_fixture()
    {:ok, %{settings_version: snapshot}} = Orgs.update_team_settings(team, %{"a" => 1})

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.update_all(
        from(v in TeamSettingsVersion, where: v.id == ^snapshot.id),
        set: [settings_hash: "tampered"]
      )
    end

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.delete_all(from(v in TeamSettingsVersion, where: v.id == ^snapshot.id))
    end
  end
end
