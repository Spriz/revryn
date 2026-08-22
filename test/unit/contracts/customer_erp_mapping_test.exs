defmodule BillingCore.Contracts.CustomerErpMappingTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Contracts.CustomerErpMapping

  defp changeset(attrs) do
    CustomerErpMapping.changeset(%CustomerErpMapping{}, attrs)
  end

  test "valid with an external customer number and a validation status" do
    validated_at = ~U[2026-08-01 12:00:00.000000Z]

    changeset =
      changeset(%{
        external_customer_number: "1001",
        validation_status: "validated",
        external_snapshot: %{"name" => "ACME"},
        external_snapshot_hash: "abc123",
        validated_at: validated_at
      })

    assert changeset.valid?
    assert get_change(changeset, :external_customer_number) == "1001"
    assert get_change(changeset, :validation_status) == "validated"
    assert get_change(changeset, :external_snapshot) == %{"name" => "ACME"}
    assert get_change(changeset, :validated_at) == validated_at
  end

  test "external customer number and validation status are required" do
    changeset = changeset(%{})

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:external_customer_number]
    assert {"can't be blank", _} = changeset.errors[:validation_status]
  end

  test "ownership and identity fields are never cast from attrs" do
    changeset =
      changeset(%{
        external_customer_number: "1001",
        validation_status: "validated",
        team_id: Ecto.UUID.generate(),
        erp_connection_id: Ecto.UUID.generate(),
        customer_id: Ecto.UUID.generate()
      })

    assert changeset.valid?
    refute Map.has_key?(changeset.changes, :team_id)
    refute Map.has_key?(changeset.changes, :erp_connection_id)
    refute Map.has_key?(changeset.changes, :customer_id)
  end

  test "declares both team-scoped unique constraints" do
    changeset = changeset(%{external_customer_number: "1001", validation_status: "validated"})

    assert [first, second] = changeset.constraints
    assert first.type == :unique
    assert second.type == :unique

    names = Enum.sort([first.constraint, second.constraint])

    assert names == [
             "customer_erp_mappings_team_id_erp_connection_id_customer_id_index",
             "customer_erp_mappings_team_id_erp_connection_id_external_customer_number_index"
           ]
  end
end
