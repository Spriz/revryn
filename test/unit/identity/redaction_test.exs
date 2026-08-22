defmodule BillingCore.Identity.RedactionTest do
  @moduledoc """
  Secret redaction in `inspect/1` output (SPEC §19.2).

  The Identity schemas mark their secret material with `redact: true`, which
  makes Ecto derive custom `Inspect` implementations. These tests pin the
  security property those implementations exist for: anything that inspects
  a session, recovery code, or TOTP factor — crash reports, Logger metadata,
  LiveView exception pages — must never see the secret material, while
  non-secret fields stay visible for debugging.
  """

  use ExUnit.Case, async: true

  alias BillingCore.Identity.{RecoveryCode, Session, TotpFactor}

  @token_hash "6c9f8ffabc1ecdd23a8e0ac59a92e7e837cf8f0c33a7a89b8c4a71bd914ea1de"
  @code_hash "2b8a61b1c8ecacdb17b6e8b3a34cdd15e08b3f0c73d8908f9d2b2f5f7f0a9c11"
  @totp_ciphertext <<1, 2, 3, "raw-totp-secret-envelope", 255, 254>>

  describe "Session inspection" do
    test "never leaks the token hash but keeps operational fields visible" do
      session = %Session{
        id: "8a2e9c1e-0000-4000-8000-000000000001",
        token_hash: @token_hash,
        strength: :passkey_plus_totp,
        ip: "192.0.2.10",
        user_agent: "test-agent/1.0",
        authenticated_at: ~U[2026-08-22 10:00:00.000000Z]
      }

      output = inspect(session)

      refute output =~ @token_hash
      assert output =~ "BillingCore.Identity.Session"
      assert output =~ ":passkey_plus_totp"
      assert output =~ "192.0.2.10"
      assert output =~ "test-agent/1.0"
    end

    test "redaction holds for pretty and infinite-limit inspection" do
      session = %Session{token_hash: @token_hash, strength: :passkey}

      refute inspect(session, pretty: true, limit: :infinity, printable_limit: :infinity) =~
               @token_hash
    end
  end

  describe "RecoveryCode inspection" do
    test "never leaks the code hash but shows batch and consumption state" do
      code = %RecoveryCode{
        id: "8a2e9c1e-0000-4000-8000-000000000002",
        code_hash: @code_hash,
        batch: 3,
        consumed_at: ~U[2026-08-22 09:30:00.000000Z]
      }

      output = inspect(code)

      refute output =~ @code_hash
      assert output =~ "BillingCore.Identity.RecoveryCode"
      assert output =~ "batch: 3"
      assert output =~ "2026-08-22 09:30:00"
    end

    test "a changeset carrying a code hash change does not expose it either" do
      changeset = RecoveryCode.changeset(%RecoveryCode{}, %{code_hash: @code_hash, batch: 1})

      refute inspect(changeset) =~ @code_hash
    end
  end

  describe "TotpFactor inspection" do
    test "never leaks the encrypted secret but shows lifecycle fields" do
      factor = %TotpFactor{
        id: "8a2e9c1e-0000-4000-8000-000000000003",
        secret_ciphertext: @totp_ciphertext,
        activated_at: ~U[2026-08-22 08:00:00.000000Z],
        last_timestep: 59_000_000
      }

      output = inspect(factor)

      refute output =~ inspect(@totp_ciphertext)
      refute output =~ "raw-totp-secret-envelope"
      assert output =~ "BillingCore.Identity.TotpFactor"
      assert output =~ "last_timestep: 59000000"
      assert output =~ "2026-08-22 08:00:00"
    end

    test "a changeset carrying the ciphertext does not expose it either" do
      changeset = TotpFactor.changeset(%TotpFactor{}, %{secret_ciphertext: @totp_ciphertext})

      refute inspect(changeset) =~ "raw-totp-secret-envelope"
    end
  end
end
