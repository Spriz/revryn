defmodule BillingCore.Identity.RecoveryTest do
  @moduledoc """
  Recovery codes (SPEC §19.2, BC-US-146): hashed at rest, single-use with
  atomic consumption, batch regeneration invalidating the previous batch,
  and mandatory alongside TOTP.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.{Audit, Identity}
  alias BillingCore.Identity.RecoveryCode

  import BillingCore.IdentityFixtures

  describe "generation" do
    test "requires an active TOTP factor" do
      assert {:error, :totp_not_enabled} = Identity.generate_recovery_codes(user_fixture())
    end

    test "TOTP confirmation issues 10 formatted codes, stored only as hashes" do
      user = user_fixture()
      %{recovery_codes: codes} = enrolled_totp_fixture(user)

      assert length(codes) == 10
      assert Enum.uniq(codes) == codes
      assert Enum.all?(codes, &(&1 =~ ~r/^[A-Z2-7]{4}(-[A-Z2-7]{4}){3}$/))

      stored = Repo.all(from c in RecoveryCode, where: c.user_id == ^user.id)
      assert length(stored) == 10
      assert Enum.all?(stored, &(&1.batch == 1))
      assert Enum.all?(stored, &is_nil(&1.consumed_at))
      refute Enum.any?(stored, fn record -> record.code_hash in codes end)
    end
  end

  describe "consumption" do
    test "a code works exactly once (audited), atomically" do
      user = user_fixture()
      %{recovery_codes: [code | _rest]} = enrolled_totp_fixture(user)

      assert :ok = Identity.consume_recovery_code(user, code)
      assert {:error, :invalid_code} = Identity.consume_recovery_code(user, code)

      assert length(Identity.list_recovery_codes(user)) == 9

      assert [entry] =
               Repo.all(
                 from e in Audit.Entry,
                   where: e.event_type == "identity.recovery_code.consumed"
               )

      assert entry.payload["user_id"] == user.id
    end

    test "input is normalized: case and separators are ignored" do
      user = user_fixture()
      %{recovery_codes: [code | _rest]} = enrolled_totp_fixture(user)

      sloppy = code |> String.downcase() |> String.replace("-", " ")
      assert :ok = Identity.consume_recovery_code(user, sloppy)
    end

    test "codes are scoped to their user" do
      user = user_fixture()
      other = user_fixture()
      %{recovery_codes: [code | _rest]} = enrolled_totp_fixture(user)

      assert {:error, :invalid_code} = Identity.consume_recovery_code(other, code)
      assert :ok = Identity.consume_recovery_code(user, code)
    end

    test "unknown codes are rejected" do
      user = user_fixture()
      enrolled_totp_fixture(user)

      assert {:error, :invalid_code} = Identity.consume_recovery_code(user, "NOPE-NOPE-NOPE-NOPE")
    end
  end

  describe "regeneration" do
    test "a new batch invalidates all unconsumed codes of the previous batch" do
      user = user_fixture()
      %{recovery_codes: [consumed_code | [old_code | _rest]]} = enrolled_totp_fixture(user)

      assert :ok = Identity.consume_recovery_code(user, consumed_code)

      assert {:ok, %{codes: new_codes, batch: 2}} = Identity.generate_recovery_codes(user)
      assert length(new_codes) == 10

      # Old unconsumed codes are gone; the new batch is fully usable.
      assert {:error, :invalid_code} = Identity.consume_recovery_code(user, old_code)
      assert :ok = Identity.consume_recovery_code(user, hd(new_codes))

      assert length(Identity.list_recovery_codes(user)) == 9
      assert Identity.list_recovery_codes(user, 2) |> length() == 9

      # Consumed codes remain as historical records.
      consumed =
        Repo.all(
          from c in RecoveryCode, where: c.user_id == ^user.id and not is_nil(c.consumed_at)
        )

      assert length(consumed) == 2
    end
  end
end
