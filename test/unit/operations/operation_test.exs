defmodule BillingCore.Operations.OperationTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Operations.Operation

  describe "states/0 and error_classes/0" do
    test "lists the SPEC §22.9.2 lifecycle states" do
      assert Operation.states() ==
               ~w(queued executing succeeded retry_scheduled outcome_unknown reconciling blocked failed)
    end

    test "lists the SPEC §22.9.1 error classes" do
      assert Operation.error_classes() ==
               ~w(transient throttled dependency_unavailable validation authorization conflict outcome_unknown poison terminal)
    end
  end

  describe "create_changeset/1" do
    test "valid with a dotted type and an actor, defaulting to queued" do
      team_id = Ecto.UUID.generate()

      changeset =
        Operation.create_changeset(%{
          type: "erp.create_draft",
          actor_type: "system",
          team_id: team_id,
          metadata: %{"intent_id" => "abc"}
        })

      assert changeset.valid?
      assert get_change(changeset, :type) == "erp.create_draft"
      assert get_change(changeset, :team_id) == team_id
      assert get_field(changeset, :state) == "queued"
      assert get_field(changeset, :attempt_count) == 0
    end

    test "type and actor_type are required" do
      changeset = Operation.create_changeset(%{})

      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:type]
      assert {"can't be blank", _} = changeset.errors[:actor_type]
    end

    test "type must be lower-case dotted/underscored" do
      changeset = Operation.create_changeset(%{type: "ERP Create!", actor_type: "system"})

      refute changeset.valid?
      assert {"has invalid format", _} = changeset.errors[:type]
    end

    test "lifecycle fields are never cast at creation" do
      changeset =
        Operation.create_changeset(%{
          type: "erp.create_draft",
          actor_type: "system",
          state: "succeeded",
          attempt_count: 5,
          version: 9
        })

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :state)
      refute Map.has_key?(changeset.changes, :attempt_count)
      refute Map.has_key?(changeset.changes, :version)
    end
  end

  describe "update_changeset/2" do
    test "valid state and error class updates carry the optimistic lock" do
      operation = %Operation{state: "executing", version: 3}

      changeset =
        Operation.update_changeset(operation, %{
          state: "retry_scheduled",
          attempt_count: 2,
          error_class: "transient",
          safe_error_code: "connection_reset"
        })

      assert changeset.valid?
      assert get_change(changeset, :state) == "retry_scheduled"
      assert get_change(changeset, :error_class) == "transient"
      assert changeset.filters == %{version: 3}
    end

    test "rejects states outside the lifecycle" do
      changeset = Operation.update_changeset(%Operation{}, %{state: "vibing"})

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:state]
    end

    test "rejects unknown error classes" do
      changeset = Operation.update_changeset(%Operation{}, %{error_class: "surprising"})

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:error_class]
    end

    test "every declared state and error class is accepted" do
      for state <- Operation.states() do
        assert Operation.update_changeset(%Operation{}, %{state: state}).valid?
      end

      for error_class <- Operation.error_classes() do
        assert Operation.update_changeset(%Operation{}, %{error_class: error_class}).valid?
      end
    end
  end
end
