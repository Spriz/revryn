defmodule BillingCore.Identity.SessionTest do
  use BillingCore.DataCase, async: true

  alias BillingCore.{Audit, Identity}
  alias BillingCore.Identity.Session

  import BillingCore.IdentityFixtures

  describe "create_session/2" do
    test "returns a plain token and persists only its SHA-256 hash" do
      user = user_fixture()

      {plain_token, session} = Identity.create_session(user)

      # the plain token is 32 random bytes, URL-base64 encoded
      raw = Base.url_decode64!(plain_token, padding: false)
      assert byte_size(raw) == 32

      # the stored value is the lowercase hex SHA-256 of those bytes — the
      # plain token never touches the database
      assert session.token_hash == Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
      assert String.match?(session.token_hash, ~r/^[0-9a-f]{64}$/)
      refute session.token_hash =~ plain_token

      stored = Repo.get!(Session, session.id)
      assert stored.token_hash == session.token_hash
    end

    test "defaults strength, authentication time, and expiry" do
      user = user_fixture()

      {_token, session} = Identity.create_session(user)

      assert session.strength == :passkey
      assert DateTime.diff(DateTime.utc_now(), session.authenticated_at, :second) < 5
      assert DateTime.after?(session.expires_at, DateTime.utc_now())
    end

    test "accepts explicit strength and security metadata" do
      user = user_fixture()

      {_token, session} =
        Identity.create_session(user, %{
          strength: :passkey_plus_totp,
          ip: "192.0.2.10",
          user_agent: "test-agent"
        })

      assert session.strength == :passkey_plus_totp
      assert session.ip == "192.0.2.10"
      assert session.user_agent == "test-agent"
    end
  end

  describe "get_user_by_session_token/1" do
    test "round-trips a valid token to its user" do
      user = user_fixture()
      {plain_token, _session} = Identity.create_session(user)

      assert %{id: id} = Identity.get_user_by_session_token(plain_token)
      assert id == user.id
    end

    test "rejects malformed and unknown tokens" do
      user = user_fixture()
      {_plain_token, _session} = Identity.create_session(user)

      assert Identity.get_user_by_session_token("%%% not base64 %%%") == nil

      other = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      assert Identity.get_user_by_session_token(other) == nil
    end

    test "rejects expired sessions" do
      user = user_fixture()

      {plain_token, _session} =
        Identity.create_session(user, %{
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      assert Identity.get_user_by_session_token(plain_token) == nil
    end

    test "rejects revoked sessions" do
      user = user_fixture()
      {plain_token, session} = Identity.create_session(user)

      {:ok, _revoked} = Identity.revoke_session(session)

      assert Identity.get_user_by_session_token(plain_token) == nil
    end

    test "rejects sessions of disabled users" do
      user = user_fixture()
      {plain_token, _session} = Identity.create_session(user)

      user |> Ecto.Changeset.change(status: :disabled) |> Repo.update!()

      assert Identity.get_user_by_session_token(plain_token) == nil
    end
  end

  describe "revocation" do
    test "revoke_session/1 is idempotent and audited" do
      user = user_fixture()
      {_plain_token, session} = Identity.create_session(user)

      assert {:ok, revoked} = Identity.revoke_session(session)
      assert %DateTime{} = revoked.revoked_at

      # idempotent: revoking again does not change the timestamp
      assert {:ok, revoked_again} = Identity.revoke_session(revoked)
      assert revoked_again.revoked_at == revoked.revoked_at

      assert [entry] = session_revocation_audit_entries()
      assert entry.aggregate_id == session.id
      assert entry.payload["user_id"] == user.id
    end

    test "revoke_all_sessions/1 revokes every active session and audits each" do
      user = user_fixture()
      {token_1, _} = Identity.create_session(user)
      {token_2, _} = Identity.create_session(user)
      {token_3, already_revoked} = Identity.create_session(user)
      {:ok, _} = Identity.revoke_session(already_revoked)

      assert {:ok, revoked} = Identity.revoke_all_sessions(user)
      assert length(revoked) == 2

      for token <- [token_1, token_2, token_3] do
        assert Identity.get_user_by_session_token(token) == nil
      end

      # one audit entry per revocation (2 bulk + 1 earlier single)
      assert length(session_revocation_audit_entries()) == 3
    end
  end

  defp session_revocation_audit_entries do
    Repo.all(from e in Audit.Entry, where: e.event_type == "identity.session.revoked")
  end
end
