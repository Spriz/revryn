defmodule BillingCore.Identity.TotpTest do
  @moduledoc """
  TOTP lifecycle (SPEC §19.2, BC-US-146): envelope-encrypted seeds,
  enrollment confirmation with a real generated code, ±1-period drift,
  replay rejection via `last_timestep`, and removal with proof of
  possession (invalidating recovery codes and step-up sessions).
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.{Audit, Identity}
  alias BillingCore.Identity.{RecoveryCode, Totp}

  import BillingCore.IdentityFixtures

  @period 30

  defp code_at(secret, at), do: NimbleTOTP.verification_code(secret, time: at)

  describe "secret envelope encryption" do
    test "round-trips and never stores the plaintext seed" do
      secret = Totp.generate_secret()
      envelope = Totp.encrypt_secret(secret)

      refute envelope == secret
      assert :binary.match(envelope, secret) == :nomatch
      assert {:ok, ^secret} = Totp.decrypt_secret(envelope)
    end

    test "uses a fresh IV per envelope" do
      secret = Totp.generate_secret()
      assert Totp.encrypt_secret(secret) != Totp.encrypt_secret(secret)
    end

    test "rejects tampered or foreign ciphertext" do
      secret = Totp.generate_secret()
      <<version, rest::binary>> = Totp.encrypt_secret(secret)
      tampered = <<version>> <> <<0>> <> binary_part(rest, 1, byte_size(rest) - 1)

      assert {:error, :decryption_failed} = Totp.decrypt_secret(tampered)
      assert {:error, :decryption_failed} = Totp.decrypt_secret(<<9, 9, 9>>)
    end
  end

  describe "matching_timestep/2" do
    test "defaults `at` to the current OS time" do
      secret = Totp.generate_secret()
      before = System.os_time(:second)
      code = code_at(secret, before)

      # The default-`at` head evaluates System.os_time/1 at call time; the
      # current code must match a timestep inside the ±1-period drift window
      # around now.
      assert {:ok, timestep} = Totp.matching_timestep(secret, code)
      assert_in_delta timestep, div(before, @period), 1
    end

    test "returns :error for a code outside the drift window" do
      secret = Totp.generate_secret()
      now = System.os_time(:second)

      assert :error = Totp.matching_timestep(secret, code_at(secret, now - 3 * @period), now)
    end

    test "ignores whitespace but rejects wrong-length codes" do
      secret = Totp.generate_secret()
      now = System.os_time(:second)
      code = code_at(secret, now)
      spaced = String.slice(code, 0, 3) <> " " <> String.slice(code, 3, 3)

      assert {:ok, _} = Totp.matching_timestep(secret, spaced, now)
      assert :error = Totp.matching_timestep(secret, code <> "0", now)
    end
  end

  describe "period/0" do
    test "exposes the 30-second TOTP period" do
      assert Totp.period() == 30
    end
  end

  describe "enroll_totp/1" do
    test "stores an inactive factor with the encrypted seed and returns the otpauth URI" do
      user = user_fixture()

      assert {:ok, %{factor: factor, secret: secret, otpauth_uri: uri}} =
               Identity.enroll_totp(user)

      assert factor.activated_at == nil
      assert factor.last_timestep == nil
      refute factor.secret_ciphertext == secret
      assert {:ok, ^secret} = Totp.decrypt_secret(factor.secret_ciphertext)

      assert uri =~ "otpauth://totp/"
      assert uri =~ "issuer=Billing%20Core"
      assert uri =~ Base.encode32(secret, padding: false)
    end

    test "re-enrolling replaces a pending factor and is refused once active" do
      user = user_fixture()

      {:ok, %{factor: first}} = Identity.enroll_totp(user)
      {:ok, %{factor: second, secret: secret}} = Identity.enroll_totp(user)

      refute first.id == second.id
      assert [%{id: pending_id}] = Identity.list_totp_factors(user)
      assert pending_id == second.id

      at = System.os_time(:second)
      assert {:ok, _result} = Identity.confirm_totp(user, code_at(secret, at), at: at)
      assert {:error, :already_enabled} = Identity.enroll_totp(user)
    end
  end

  describe "confirm_totp/3" do
    test "activates the factor with a valid code and issues 10 hashed recovery codes" do
      user = user_fixture()
      {:ok, %{secret: secret}} = Identity.enroll_totp(user)
      at = System.os_time(:second)

      assert {:ok, %{factor: factor, recovery_codes: codes}} =
               Identity.confirm_totp(user, code_at(secret, at), at: at)

      assert %DateTime{} = factor.activated_at
      assert factor.last_timestep == div(at, @period)
      assert length(codes) == 10
      assert Enum.uniq(codes) == codes

      stored_hashes = Repo.all(from c in RecoveryCode, select: c.code_hash)
      assert length(stored_hashes) == 10
      refute Enum.any?(codes, &(&1 in stored_hashes))
    end

    test "rejects an invalid code, leaving the factor inactive" do
      user = user_fixture()
      {:ok, _enrollment} = Identity.enroll_totp(user)

      assert {:error, :invalid_code} = Identity.confirm_totp(user, "000000")
      assert Identity.get_active_totp_factor(user) == nil
      assert Identity.list_recovery_codes(user) == []
    end

    test "requires an enrollment to confirm" do
      assert {:error, :not_enrolled} = Identity.confirm_totp(user_fixture(), "123456")
    end
  end

  describe "verify_totp/3 (step-up)" do
    setup do
      user = user_fixture()
      %{secret: secret} = enrolled_totp_fixture(user)
      %{user: user, secret: secret, now: System.os_time(:second)}
    end

    test "accepts the current code once and rejects its replay", ctx do
      code = code_at(ctx.secret, ctx.now)

      assert :ok = Identity.verify_totp(ctx.user, code, at: ctx.now)
      assert {:error, :code_already_used} = Identity.verify_totp(ctx.user, code, at: ctx.now)
    end

    test "accepts one period of clock drift in both directions", ctx do
      assert :ok =
               Identity.verify_totp(ctx.user, code_at(ctx.secret, ctx.now - @period), at: ctx.now)

      later = ctx.now + 10 * @period
      assert :ok = Identity.verify_totp(ctx.user, code_at(ctx.secret, later + @period), at: later)
    end

    test "rejects codes beyond the drift window", ctx do
      assert {:error, :invalid_code} =
               Identity.verify_totp(ctx.user, code_at(ctx.secret, ctx.now - 2 * @period),
                 at: ctx.now
               )

      assert {:error, :invalid_code} =
               Identity.verify_totp(ctx.user, code_at(ctx.secret, ctx.now + 2 * @period),
                 at: ctx.now
               )
    end

    test "rejects a drifted code whose timestep was already surpassed", ctx do
      assert :ok = Identity.verify_totp(ctx.user, code_at(ctx.secret, ctx.now), at: ctx.now)

      # The previous period's code is inside the drift window but its
      # timestep is not newer than the last accepted one.
      assert {:error, :code_already_used} =
               Identity.verify_totp(ctx.user, code_at(ctx.secret, ctx.now - @period), at: ctx.now)
    end

    test "rejects garbage and wrong-length input", ctx do
      assert {:error, :invalid_code} = Identity.verify_totp(ctx.user, "12345", at: ctx.now)
      assert {:error, :invalid_code} = Identity.verify_totp(ctx.user, "not-a-code", at: ctx.now)
    end

    test "requires an active factor" do
      assert {:error, :not_enabled} = Identity.verify_totp(user_fixture(), "123456")
    end
  end

  describe "remove_totp/3" do
    test "requires a valid current code" do
      user = user_fixture()
      enrolled_totp_fixture(user)

      assert {:error, :invalid_code} = Identity.remove_totp(user, "000000")
      assert Identity.totp_enabled?(user)
    end

    test "revokes the factor, invalidates recovery codes, and revokes step-up sessions" do
      user = user_fixture()
      %{secret: secret} = enrolled_totp_fixture(user)

      {_token, step_up_session} =
        Identity.create_session(user, %{strength: :passkey_plus_totp})

      {_token, passkey_session} = Identity.create_session(user, %{strength: :passkey})

      now = System.os_time(:second)
      assert {:ok, revoked} = Identity.remove_totp(user, code_at(secret, now), at: now)

      assert %DateTime{} = revoked.revoked_at
      refute Identity.totp_enabled?(user)
      assert Identity.list_recovery_codes(user) == []

      session_ids = Enum.map(Identity.list_active_sessions(user), & &1.id)
      refute step_up_session.id in session_ids
      assert passkey_session.id in session_ids

      assert [entry] =
               Repo.all(
                 from e in Audit.Entry,
                   where: e.event_type == "identity.totp_factor.revoked"
               )

      assert entry.aggregate_id == revoked.id
    end
  end
end
