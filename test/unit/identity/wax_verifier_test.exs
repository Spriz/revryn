defmodule BillingCore.Identity.WaxVerifierTest do
  @moduledoc """
  The production `Verifier` backed by the real Wax library (SPEC §19.2) —
  no stubbing at the verifier boundary here.

  Success paths are exercised with genuine cryptographic material: a fresh
  P-256 key pair, a hand-assembled authenticator-data binary, a real ECDSA
  assertion signature, and (for registration) a fabricated `"none"`-format
  CBOR attestation object, all of which Wax validates in full. What is
  deliberately NOT covered: attestation statement formats that verify
  authenticator certificate chains (`packed`, `tpm`, `android-key`,
  `fido-u2f`, `apple`) — those require real vendor certificates and are
  covered by the Playwright virtual-authenticator suite (SPEC §23.10).
  Origin/RP-ID/challenge mismatch rejections for registration live in
  `webauthn_test.exs`.
  """

  # No DB access; challenge building only reads application config.
  use ExUnit.Case, async: true

  import Bitwise

  alias BillingCore.Identity.WebAuthn
  alias BillingCore.Identity.WebAuthn.WaxVerifier
  alias BillingCore.Identity.WebauthnCredential

  @origin "http://localhost:4000"
  @rp_id "localhost"

  # WebAuthn authenticator-data flag bits (least significant first):
  # user present (0x01), user verified (0x04), backup eligible (0x08),
  # backup state (0x10), attested credential data included (0x40).
  @flag_user_present 0x01
  @flag_backup_eligible 0x08
  @flag_attested_credential_data 0x40

  defp new_p256_key do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    <<4, x::binary-size(32), y::binary-size(32)>> = public
    cose_key = %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}
    {cose_key, private}
  end

  defp client_data_json(type, challenge, origin \\ @origin) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => Base.url_encode64(challenge.bytes, padding: false),
      "origin" => origin
    })
  end

  defp authenticator_data(flags, sign_count, tail \\ <<>>) do
    :crypto.hash(:sha256, @rp_id) <>
      <<flags::unsigned-integer-size(8), sign_count::unsigned-big-integer-size(32)>> <> tail
  end

  # CBOR-encodes a COSE key, marking binary values as CBOR byte strings.
  defp cbor_cose_key(cose_key) do
    cose_key
    |> Map.new(fn
      {k, v} when is_binary(v) -> {k, %CBOR.Tag{tag: :bytes, value: v}}
      {k, v} -> {k, v}
    end)
    |> CBOR.encode()
  end

  # A structurally valid "none"-format attestation object: zero AAGUID,
  # length-prefixed credential ID, CBOR COSE public key.
  defp attestation_object(credential_id, cose_key, flags, sign_count) do
    attested_credential_data =
      <<0::size(128), byte_size(credential_id)::unsigned-big-integer-size(16)>> <>
        credential_id <> cbor_cose_key(cose_key)

    auth_data = authenticator_data(flags, sign_count, attested_credential_data)

    CBOR.encode(%{
      "fmt" => "none",
      "attStmt" => %{},
      "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
    })
  end

  defp authentication_challenge(credential_id, cose_key) do
    WebAuthn.authentication_challenge([
      %WebauthnCredential{
        credential_id: credential_id,
        public_key: WebAuthn.serialize_cose_key(cose_key)
      }
    ])
  end

  describe "verify_registration/3 (real Wax attestation validation)" do
    test "accepts a none-format attestation and extracts the credential material" do
      {cose_key, _private} = new_p256_key()
      challenge = WebAuthn.registration_challenge()
      flags = @flag_user_present ||| @flag_attested_credential_data ||| @flag_backup_eligible

      attestation = attestation_object("wax-registered-cred", cose_key, flags, 7)

      assert {:ok, result} =
               WaxVerifier.verify_registration(
                 attestation,
                 client_data_json("webauthn.create", challenge),
                 challenge
               )

      assert result.credential_id == "wax-registered-cred"
      assert result.cose_key == cose_key
      assert result.sign_count == 7
      assert result.backup_eligible == true
      assert result.backup_state == false
    end

    test "propagates Wax errors for a malformed (non-CBOR) attestation object" do
      challenge = WebAuthn.registration_challenge()

      assert {:error, %Wax.InvalidCBORError{}} =
               WaxVerifier.verify_registration(
                 <<0xFF, 0xFF, 0xFF>>,
                 client_data_json("webauthn.create", challenge),
                 challenge
               )
    end
  end

  describe "verify_authentication/5 (real Wax assertion validation)" do
    test "accepts a genuine ECDSA assertion and reports the new sign count" do
      {cose_key, private} = new_p256_key()
      challenge = authentication_challenge("wax-auth-cred", cose_key)

      auth_data = authenticator_data(@flag_user_present, 9)
      client_data = client_data_json("webauthn.get", challenge)
      message = auth_data <> :crypto.hash(:sha256, client_data)
      signature = :crypto.sign(:ecdsa, :sha256, message, [private, :secp256r1])

      assert {:ok, %{sign_count: 9}} =
               WaxVerifier.verify_authentication(
                 "wax-auth-cred",
                 auth_data,
                 signature,
                 client_data,
                 challenge
               )
    end

    test "rejects a signature that does not verify against the registered key" do
      {cose_key, private} = new_p256_key()
      challenge = authentication_challenge("wax-auth-cred", cose_key)

      auth_data = authenticator_data(@flag_user_present, 9)
      client_data = client_data_json("webauthn.get", challenge)
      # Signature over the wrong message — as a tampered assertion would be.
      signature = :crypto.sign(:ecdsa, :sha256, "wrong message", [private, :secp256r1])

      assert {:error, %Wax.InvalidSignatureError{}} =
               WaxVerifier.verify_authentication(
                 "wax-auth-cred",
                 auth_data,
                 signature,
                 client_data,
                 challenge
               )
    end

    test "rejects a credential that is not in the challenge allow-list" do
      {cose_key, private} = new_p256_key()
      challenge = authentication_challenge("allowed-cred", cose_key)

      auth_data = authenticator_data(@flag_user_present, 1)
      client_data = client_data_json("webauthn.get", challenge)
      message = auth_data <> :crypto.hash(:sha256, client_data)
      signature = :crypto.sign(:ecdsa, :sha256, message, [private, :secp256r1])

      assert {:error, %Wax.InvalidClientDataError{reason: :credential_id_mismatch}} =
               WaxVerifier.verify_authentication(
                 "some-other-cred",
                 auth_data,
                 signature,
                 client_data,
                 challenge
               )
    end

    test "rejects malformed authenticator data" do
      {cose_key, _private} = new_p256_key()
      challenge = authentication_challenge("wax-auth-cred", cose_key)

      assert {:error, %Wax.InvalidAuthenticatorDataError{}} =
               WaxVerifier.verify_authentication(
                 "wax-auth-cred",
                 <<1, 2, 3>>,
                 <<0>>,
                 client_data_json("webauthn.get", challenge),
                 challenge
               )
    end
  end
end
