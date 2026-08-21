defmodule BillingCore.Operations.ListRecentTest do
  use BillingCore.DataCase, async: true

  alias BillingCore.Operations

  test "list_recent/2 returns the team's operations newest first, capped" do
    team_id = Ecto.UUID.generate()
    other_team_id = Ecto.UUID.generate()

    first =
      Operations.create!(%{team_id: team_id, type: "erp.create_draft", actor_type: "user"})

    second =
      Operations.create!(%{team_id: team_id, type: "erp.book_document", actor_type: "user"})

    _elsewhere =
      Operations.create!(%{team_id: other_team_id, type: "erp.create_draft", actor_type: "user"})

    recent = Operations.list_recent(team_id)

    assert Enum.map(recent, & &1.id) == [second.id, first.id]
    assert [%{id: latest_id}] = Operations.list_recent(team_id, 1)
    assert latest_id == second.id
  end
end
