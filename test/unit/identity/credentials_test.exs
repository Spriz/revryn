defmodule BillingCore.Identity.CredentialsTest do
  @moduledoc """
  Persistence, listing, and revocation of authentication credential
  material (SPEC §13.3, §19.2). Ceremony logic (WebAuthn challenges, TOTP
  verification) is intentionally out of scope for the Identity context.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.{Audit, Identity}

  import BillingCore.IdentityFixtures

  describe "WebAuthn credentials" do
    test "register, list, and revoke (audited)" do
      user = user_fixture()

      assert {:ok, credential} =
               Identity.register_webauthn_credential(user, %{
                 credential_id: <<1, 2, 3, 4>>,
                 public_key: <<5, 6, 7, 8>>,
                 name: "YubiKey",
                 transports: ["usb", "nfc"],
                 backup_eligible: false
               })

      assert credential.sign_count == 0
      assert [%{id: id}] = Identity.list_webauthn_credentials(user)
      assert id == credential.id

      assert {:ok, revoked} = Identity.revoke_webauthn_credential(credential)
      assert %DateTime{} = revoked.revoked_at
      assert Identity.list_webauthn_credentials(user) == []

      # idempotent
      assert {:ok, ^revoked} = Identity.revoke_webauthn_credential(revoked)

      assert [entry] = audit_entries("identity.webauthn_credential.revoked")
      assert entry.aggregate_id == credential.id
    end

    test "credential IDs are globally unique" do
      user = user_fixture()
      other = user_fixture()
      attrs = %{credential_id: <<9, 9, 9>>, public_key: <<1>>, name: "Key"}

      assert {:ok, _} = Identity.register_webauthn_credential(user, attrs)
      assert {:error, changeset} = Identity.register_webauthn_credential(other, attrs)
      assert %{credential_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "TOTP factors" do
    test "create, list, and revoke (audited)" do
      user = user_fixture()

      assert {:ok, factor} =
               Identity.create_totp_factor(user, %{secret_ciphertext: <<0, 1, 2, 3>>})

      assert factor.activated_at == nil
      assert [%{id: id}] = Identity.list_totp_factors(user)
      assert id == factor.id

      assert {:ok, revoked} = Identity.revoke_totp_factor(factor)
      assert %DateTime{} = revoked.revoked_at
      assert Identity.list_totp_factors(user) == []

      assert [entry] = audit_entries("identity.totp_factor.revoked")
      assert entry.aggregate_id == factor.id
    end
  end

  describe "recovery codes" do
    test "stores pre-hashed codes in batches and lists unconsumed ones" do
      user = user_fixture()
      hashes = for i <- 1..3, do: "hash-#{i}"

      assert {:ok, codes} = Identity.insert_recovery_codes(user, hashes, 1)
      assert length(codes) == 3
      assert length(Identity.list_recovery_codes(user)) == 3
      assert length(Identity.list_recovery_codes(user, 1)) == 3
      assert Identity.list_recovery_codes(user, 2) == []

      # a consumed code disappears from the listing
      [first | _] = codes
      first |> Ecto.Changeset.change(consumed_at: DateTime.utc_now()) |> Repo.update!()
      assert length(Identity.list_recovery_codes(user)) == 2
    end
  end

  describe "federated identities" do
    test "links an issuer/subject pair once and resolves it back" do
      user = user_fixture()

      assert {:ok, _identity} =
               Identity.link_federated_identity(user, "https://idp.example.com", "subject-1")

      assert Identity.get_user_by_federated_identity("https://idp.example.com", "subject-1").id ==
               user.id

      assert Identity.get_user_by_federated_identity("https://idp.example.com", "other") == nil

      other_user = user_fixture()

      assert {:error, :already_linked} =
               Identity.link_federated_identity(
                 other_user,
                 "https://idp.example.com",
                 "subject-1"
               )
    end
  end

  defp audit_entries(event_type) do
    Repo.all(from e in Audit.Entry, where: e.event_type == ^event_type)
  end
end
