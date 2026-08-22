defmodule BillingCore.Credits.DispositionPolicyVersionTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias BillingCore.Credits.DispositionPolicyVersion

  @effective_from ~U[2026-08-01 00:00:00.000000Z]

  defp changeset(attrs) do
    DispositionPolicyVersion.create_changeset(%DispositionPolicyVersion{}, attrs)
  end

  test "policies/0 lists the supported dispositions" do
    assert DispositionPolicyVersion.policies() == [:retain, :refund, :expire_after]
  end

  test "retain and refund policies are valid without expiry days" do
    for policy <- [:retain, :refund] do
      changeset = changeset(%{policy: policy, effective_from: @effective_from})
      assert changeset.valid?, "expected #{policy} without days to be valid"
    end
  end

  test "expire_after requires positive expiry days" do
    changeset =
      changeset(%{policy: :expire_after, expire_after_days: 30, effective_from: @effective_from})

    assert changeset.valid?
    assert get_change(changeset, :expire_after_days) == 30
  end

  test "expire_after without days is rejected" do
    changeset = changeset(%{policy: :expire_after, effective_from: @effective_from})

    refute changeset.valid?

    assert {"is required for the expire_after policy", _} =
             changeset.errors[:expire_after_days]
  end

  test "non-expiring policies must not carry expiry days" do
    changeset =
      changeset(%{policy: :retain, expire_after_days: 10, effective_from: @effective_from})

    refute changeset.valid?

    assert {"is only allowed for the expire_after policy", _} =
             changeset.errors[:expire_after_days]
  end

  test "expiry days must be strictly positive" do
    changeset =
      changeset(%{policy: :expire_after, expire_after_days: 0, effective_from: @effective_from})

    refute changeset.valid?
    assert {"must be greater than %{number}", _} = changeset.errors[:expire_after_days]
  end

  test "policy and effective_from are required" do
    changeset = changeset(%{})

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:policy]
    assert {"can't be blank", _} = changeset.errors[:effective_from]
  end

  test "policies outside the enum are invalid" do
    changeset = changeset(%{policy: :donate, effective_from: @effective_from})

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:policy]
  end

  test "team, account, and version are never cast from attrs" do
    changeset =
      changeset(%{
        policy: :retain,
        effective_from: @effective_from,
        team_id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate(),
        version: 99
      })

    assert changeset.valid?
    refute Map.has_key?(changeset.changes, :team_id)
    refute Map.has_key?(changeset.changes, :account_id)
    refute Map.has_key?(changeset.changes, :version)
  end

  test "declares the team-scoped unique version constraint with its message" do
    changeset = changeset(%{policy: :retain, effective_from: @effective_from})

    assert [constraint] = changeset.constraints
    assert constraint.type == :unique
    assert constraint.error_message == "policy version already exists for this account"
  end
end
