defmodule BillingCore.Identity.WebauthnTest do
  @moduledoc """
  WebAuthn ceremony boundary (SPEC §19.2, BC-US-145): challenge
  configuration and expiry, credential persistence and uniqueness,
  email-first allow-lists, sign-counter regression, and the last-passkey
  revocation guard. Cryptographic verification is stubbed at the
  `Identity.WebAuthn.Verifier` boundary; origin/challenge validation of the
  real Wax verifier is exercised directly with crafted client data.
  """

  # async: false — stubs the :webauthn_verifier application env.
  use BillingCore.DataCase, async: false

  alias BillingCore.Identity
  alias BillingCore.Identity.WebAuthn
  alias BillingCore.Identity.WebAuthn.WaxVerifier
  alias BillingCore.IdentityFixtures.StubVerifier

  import BillingCore.IdentityFixtures

  setup :stub_webauthn_verifier

  defp registration_attrs(overrides \\ %{}) do
    %{
      attestation_object: stub_webauthn_payload(overrides),
      client_data_json: "{}",
      name: "Test key",
      transports: ["internal"]
    }
  end

  defp authentication_attrs(credential_id, overrides) do
    %{
      credential_id: credential_id,
      authenticator_data: stub_webauthn_payload(overrides),
      signature: <<0>>,
      client_data_json: "{}"
    }
  end

  defp expire(%Wax.Challenge{} = challenge) do
    %{challenge | issued_at: System.system_time(:second) - challenge.timeout - 1}
  end

  describe "challenges" do
    test "registration challenge uses configured origin/RP and a 2-minute lifetime" do
      challenge = Identity.registration_challenge()

      assert challenge.origin == "http://localhost:4000"
      assert challenge.rp_id == "localhost"
      assert challenge.user_verification == "preferred"
      assert challenge.attestation == "none"
      assert challenge.timeout == 120
      assert byte_size(challenge.bytes) >= 16
    end

    test "challenge bytes are unpredictable per challenge" do
      assert Identity.registration_challenge().bytes != Identity.registration_challenge().bytes
    end

    test "authentication challenge lists exactly the user's credentials (email-first)" do
      user = user_fixture()
      credential_a = webauthn_credential_fixture(user, credential_id: "cred-a")
      credential_b = webauthn_credential_fixture(user, credential_id: "cred-b")

      challenge = Identity.authentication_challenge([credential_a, credential_b])

      assert challenge.origin == "http://localhost:4000"
      assert challenge.rp_id == "localhost"

      assert [{"cred-a", cose_a}, {"cred-b", _cose_b}] = challenge.allow_credentials
      assert cose_a == StubVerifier.cose_key()
    end
  end

  describe "verify_registration/3" do
    test "persists the credential with serialized COSE key and metadata" do
      user = user_fixture()
      challenge = Identity.registration_challenge()

      assert {:ok, credential} =
               Identity.verify_registration(
                 user,
                 challenge,
                 registration_attrs(%{credential_id: "new-cred", sign_count: 3})
               )

      assert credential.user_id == user.id
      assert credential.credential_id == "new-cred"
      assert credential.sign_count == 3
      assert credential.name == "Test key"
      assert credential.transports == ["internal"]
      assert WebAuthn.cose_key(credential) == StubVerifier.cose_key()
      assert [%{id: id}] = Identity.list_webauthn_credentials(user)
      assert id == credential.id
    end

    test "defaults the credential name when none is provided" do
      user = user_fixture()
      challenge = Identity.registration_challenge()
      attrs = %{registration_attrs() | name: nil}

      assert {:ok, credential} = Identity.verify_registration(user, challenge, attrs)
      assert credential.name == "Passkey"
    end

    test "rejects an expired challenge before invoking the verifier" do
      user = user_fixture()
      challenge = expire(Identity.registration_challenge())

      assert {:error, :challenge_expired} =
               Identity.verify_registration(user, challenge, registration_attrs())

      assert Identity.list_webauthn_credentials(user) == []
    end

    test "rejects a credential id that is already registered (globally unique)" do
      user = user_fixture()
      other = user_fixture()
      webauthn_credential_fixture(user, credential_id: "taken")

      assert {:error, :credential_already_registered} =
               Identity.verify_registration(
                 other,
                 Identity.registration_challenge(),
                 registration_attrs(%{credential_id: "taken"})
               )
    end

    test "propagates verifier failures without storing anything" do
      user = user_fixture()

      assert {:error, :attestation_invalid} =
               Identity.verify_registration(
                 user,
                 Identity.registration_challenge(),
                 registration_attrs(%{error: :attestation_invalid})
               )

      assert Identity.list_webauthn_credentials(user) == []
    end
  end

  describe "verify_authentication/3" do
    setup do
      user = user_fixture()
      credential = webauthn_credential_fixture(user, credential_id: "auth-cred", sign_count: 5)
      challenge = Identity.authentication_challenge([credential])
      %{user: user, credential: credential, challenge: challenge}
    end

    test "verifies, bumps the counter, and stamps last_used_at", ctx do
      assert {:ok, credential} =
               Identity.verify_authentication(
                 ctx.user,
                 ctx.challenge,
                 authentication_attrs("auth-cred", %{sign_count: 6})
               )

      assert credential.sign_count == 6
      assert %DateTime{} = credential.last_used_at
    end

    test "accepts zero counters when the authenticator has none" do
      user = user_fixture()
      credential = webauthn_credential_fixture(user, credential_id: "no-counter", sign_count: 0)
      challenge = Identity.authentication_challenge([credential])

      assert {:ok, %{sign_count: 0}} =
               Identity.verify_authentication(
                 user,
                 challenge,
                 authentication_attrs("no-counter", %{sign_count: 0})
               )
    end

    test "rejects a non-increasing sign count as a possible clone", ctx do
      for regressed <- [5, 4, 0] do
        assert {:error, :sign_count_regression} =
                 Identity.verify_authentication(
                   ctx.user,
                   Identity.authentication_challenge([ctx.credential]),
                   authentication_attrs("auth-cred", %{sign_count: regressed})
                 )
      end

      # The credential is refused but not auto-revoked, and left untouched.
      assert [stored] = Identity.list_webauthn_credentials(ctx.user)
      assert stored.sign_count == 5
      assert stored.last_used_at == nil
    end

    test "rejects an expired challenge", ctx do
      assert {:error, :challenge_expired} =
               Identity.verify_authentication(
                 ctx.user,
                 expire(ctx.challenge),
                 authentication_attrs("auth-cred", %{sign_count: 6})
               )
    end

    test "rejects credentials outside the challenge allow-list", ctx do
      stranger_credential = webauthn_credential_fixture(ctx.user, credential_id: "other-cred")

      assert {:error, :credential_not_in_allow_list} =
               Identity.verify_authentication(
                 ctx.user,
                 ctx.challenge,
                 authentication_attrs("other-cred", %{sign_count: 1})
               )

      assert {:ok, _credential} =
               Identity.verify_authentication(
                 ctx.user,
                 Identity.authentication_challenge([stranger_credential]),
                 authentication_attrs("other-cred", %{sign_count: 1})
               )
    end

    test "rejects another user's or a revoked credential", ctx do
      other = user_fixture()

      assert {:error, :unknown_credential} =
               Identity.verify_authentication(
                 other,
                 ctx.challenge,
                 authentication_attrs("auth-cred", %{sign_count: 6})
               )

      {:ok, _revoked} = Identity.revoke_webauthn_credential(ctx.credential)

      assert {:error, :unknown_credential} =
               Identity.verify_authentication(
                 ctx.user,
                 ctx.challenge,
                 authentication_attrs("auth-cred", %{sign_count: 6})
               )
    end
  end

  describe "WaxVerifier origin/challenge validation (invalid origin/RP behavior)" do
    test "rejects client data whose origin does not match the configured origin" do
      challenge = Identity.registration_challenge()

      client_data =
        Jason.encode!(%{
          "type" => "webauthn.create",
          "challenge" => Base.url_encode64(challenge.bytes, padding: false),
          "origin" => "https://evil.example.com"
        })

      assert {:error, %Wax.InvalidClientDataError{}} =
               WaxVerifier.verify_registration(<<0>>, client_data, challenge)
    end

    test "rejects client data carrying a different challenge (replay/substitution)" do
      challenge = Identity.registration_challenge()
      other_challenge = Identity.registration_challenge()

      client_data =
        Jason.encode!(%{
          "type" => "webauthn.create",
          "challenge" => Base.url_encode64(other_challenge.bytes, padding: false),
          "origin" => "http://localhost:4000"
        })

      assert {:error, %Wax.InvalidClientDataError{}} =
               WaxVerifier.verify_registration(<<0>>, client_data, challenge)
    end

    test "rejects an expired challenge" do
      challenge = expire(Identity.registration_challenge())

      client_data =
        Jason.encode!(%{
          "type" => "webauthn.create",
          "challenge" => Base.url_encode64(challenge.bytes, padding: false),
          "origin" => "http://localhost:4000"
        })

      assert {:error, %Wax.ExpiredChallengeError{}} =
               WaxVerifier.verify_registration(<<0>>, client_data, challenge)
    end
  end

  describe "revoke_passkey/2 (last-credential guard)" do
    test "refuses to revoke the final passkey while TOTP is disabled" do
      user = user_fixture()
      credential = webauthn_credential_fixture(user)

      assert {:error, :last_credential} = Identity.revoke_passkey(user, credential)
      assert [_credential] = Identity.list_webauthn_credentials(user)
    end

    test "allows revoking the final passkey when an active TOTP factor exists" do
      user = user_fixture()
      credential = webauthn_credential_fixture(user)
      enrolled_totp_fixture(user)

      assert {:ok, revoked} = Identity.revoke_passkey(user, credential)
      assert %DateTime{} = revoked.revoked_at
    end

    test "allows revoking when another active passkey remains" do
      user = user_fixture()
      first = webauthn_credential_fixture(user)
      _second = webauthn_credential_fixture(user)

      assert {:ok, _revoked} = Identity.revoke_passkey(user, first)
      assert [remaining] = Identity.list_webauthn_credentials(user)
      assert remaining.id != first.id

      # ... and the remaining one is now guarded again.
      assert {:error, :last_credential} = Identity.revoke_passkey(user, remaining)
    end

    test "refuses to revoke a credential belonging to someone else" do
      user = user_fixture()
      other = user_fixture()
      credential = webauthn_credential_fixture(user)
      _other_credential = webauthn_credential_fixture(other)

      assert {:error, :not_found} = Identity.revoke_passkey(other, credential)
    end
  end
end
