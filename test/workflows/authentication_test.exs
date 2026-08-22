defmodule BillingCore.Workflows.AuthenticationTest do
  @moduledoc """
  Passkey-first authentication as documentation (BC-US-145/146, SPEC §19.2,
  §23.10): registration and sign-in ceremonies through the LiveViews with
  single-use challenges, the LiveView→controller session handoff, TOTP
  step-up and recovery-code sign-in with their session strengths, and
  credential/session self-service on the Security page.

  The cryptographic WebAuthn verification is stubbed at the documented
  `Identity.WebAuthn.Verifier` boundary; real-browser ceremonies (Chromium
  virtual authenticator) are covered by Playwright separately.
  """

  # async: false — the WebAuthn verifier stub mutates application env.
  use BillingCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BillingCore.IdentityFixtures

  alias BillingCore.Identity
  alias BillingCore.Identity.Session
  alias BillingCore.Repo

  setup :stub_webauthn_verifier

  defp log_in(conn, user, attrs \\ %{}) do
    {token, _session} = Identity.create_session(user, attrs)
    Plug.Test.init_test_session(conn, %{"user_session_token" => token})
  end

  defp registration_result(overrides) do
    %{
      "credentialId" => stub_webauthn_payload_b64(),
      "attestationObject" => stub_webauthn_payload_b64(overrides),
      "clientDataJSON" => Base.url_encode64("{}", padding: false),
      "transports" => ["internal"]
    }
  end

  defp authentication_result(credential_id, overrides) do
    %{
      "credentialId" => Base.url_encode64(credential_id, padding: false),
      "authenticatorData" => stub_webauthn_payload_b64(overrides),
      "signature" => Base.url_encode64(<<0>>, padding: false),
      "clientDataJSON" => Base.url_encode64("{}", padding: false)
    }
  end

  defp handoff_token(html) do
    [_, token] = Regex.run(~r/name="session_token" value="([^"]+)"/, html)
    token
  end

  defp session_for(token) do
    Identity.get_session_by_token(token)
  end

  describe "passkey registration (BC-US-145)" do
    test "email → challenge → attestation → credential + passkey session handoff", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#registration-form",
        registration: %{"email" => "ada@example.com", "name" => "Laptop key"}
      )
      |> render_submit()

      assert_push_event(view, "webauthn-register", %{"publicKey" => public_key})
      assert is_binary(public_key["challenge"])
      assert public_key["rp"] == %{"id" => "localhost", "name" => "Billing Core"}
      assert public_key["user"]["name"] == "ada@example.com"
      assert public_key["attestation"] == "none"
      assert public_key["timeout"] == 120_000

      html =
        render_hook(view, "webauthn-result", registration_result(%{credential_id: "ada-cred"}))

      token = handoff_token(html)

      user = Identity.get_user_by_email("ada@example.com")
      assert [credential] = Identity.list_webauthn_credentials(user)
      assert credential.credential_id == "ada-cred"
      assert credential.name == "Laptop key"
      assert credential.transports == ["internal"]

      assert %Session{strength: :passkey, user_id: user_id} = session_for(token)
      assert user_id == user.id

      # The handoff form POSTs the one-time token to the session controller,
      # which sets the cookie; the dashboard is then reachable.
      form = form(view, "#session-handoff")
      conn = follow_trigger_action(form, conn)
      assert redirected_to(conn) == ~p"/"

      conn = get(conn, ~p"/")
      document = conn |> html_response(200) |> LazyHTML.from_document()
      assert LazyHTML.filter(document, "#no-teams") != []
    end

    test "challenges are single-use: a replayed result is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#registration-form", registration: %{"email" => "solo@example.com", "name" => ""})
      |> render_submit()

      render_hook(view, "webauthn-result", registration_result(%{credential_id: "solo-cred"}))

      html =
        render_hook(view, "webauthn-result", registration_result(%{credential_id: "replay-cred"}))

      assert html =~ "no longer valid"

      user = Identity.get_user_by_email("solo@example.com")
      assert [%{credential_id: "solo-cred"}] = Identity.list_webauthn_credentials(user)
    end

    test "an account with working credentials must sign in instead", %{conn: conn} do
      user = user_fixture(email: "taken@example.com")
      webauthn_credential_fixture(user)

      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("#registration-form",
          registration: %{"email" => "taken@example.com", "name" => ""}
        )
        |> render_submit()

      assert html =~ "already exists"
      refute_push_event(view, "webauthn-register", %{})
    end

    test "a registration that never finished passkey setup can be resumed", %{conn: conn} do
      _user = user_fixture(email: "resumed@example.com")

      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#registration-form",
        registration: %{"email" => "resumed@example.com", "name" => ""}
      )
      |> render_submit()

      assert_push_event(view, "webauthn-register", %{"publicKey" => _public_key})
    end

    test "reports when the browser lacks WebAuthn support", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html = render_hook(view, "webauthn-unsupported", %{})
      assert html =~ "does not support passkeys"
    end

    test "an invalid email is rejected before any challenge is issued", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("#registration-form", registration: %{"email" => "not-an-email", "name" => ""})
        |> render_submit()

      assert html =~ "Enter a valid email address."
      refute_push_event(view, "webauthn-register", %{})
    end

    test "a disabled account cannot resume registration", %{conn: conn} do
      _user = user_fixture(email: "disabled@example.com", status: :disabled)

      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("#registration-form",
          registration: %{"email" => "disabled@example.com", "name" => ""}
        )
        |> render_submit()

      assert html =~ "already exists. Sign in instead."
      refute_push_event(view, "webauthn-register", %{})
    end

    test "a cancelled browser ceremony surfaces its message and invalidates the challenge",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#registration-form",
        registration: %{"email" => "cancel@example.com", "name" => ""}
      )
      |> render_submit()

      html = render_hook(view, "webauthn-error", %{"message" => "The operation was aborted."})
      assert html =~ "The operation was aborted."

      # Without a message the generic explanation is shown; the challenge
      # was already consumed, so a late result is now rejected.
      html = render_hook(view, "webauthn-error", %{})
      assert html =~ "The passkey ceremony was cancelled or failed."

      html = render_hook(view, "webauthn-result", registration_result(%{credential_id: "late"}))
      assert html =~ "no longer valid"
    end

    test "a malformed authenticator response is reported, not crashed on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#registration-form",
        registration: %{"email" => "garbled@example.com", "name" => ""}
      )
      |> render_submit()

      html =
        render_hook(view, "webauthn-result", %{
          "credentialId" => "!!!",
          "attestationObject" => "not base64url!!",
          "clientDataJSON" => "%%%"
        })

      assert html =~ "unreadable response"

      assert Identity.list_webauthn_credentials(Identity.get_user_by_email("garbled@example.com")) ==
               []
    end

    test "a result without transports still registers with an empty transport list",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#registration-form",
        registration: %{"email" => "no-transports@example.com", "name" => ""}
      )
      |> render_submit()

      result =
        registration_result(%{credential_id: "no-transport-cred"})
        |> Map.delete("transports")

      render_hook(view, "webauthn-result", result)

      user = Identity.get_user_by_email("no-transports@example.com")
      assert [credential] = Identity.list_webauthn_credentials(user)
      assert credential.credential_id == "no-transport-cred"
      assert credential.transports == []
    end

    test "a passkey already registered elsewhere is refused by name", %{conn: conn} do
      other = user_fixture(email: "owner@example.com")
      webauthn_credential_fixture(other, credential_id: "shared-cred")

      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#registration-form", registration: %{"email" => "thief@example.com", "name" => ""})
      |> render_submit()

      html =
        render_hook(view, "webauthn-result", registration_result(%{credential_id: "shared-cred"}))

      assert html =~ "That passkey is already registered."
    end

    test "verifier failures map to actionable errors", %{conn: conn} do
      # The stubbed verifier boundary injects the errors Wax would produce;
      # the ceremony itself cannot age or misattest inside a unit test.
      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#registration-form",
        registration: %{"email" => "expired@example.com", "name" => ""}
      )
      |> render_submit()

      html =
        render_hook(view, "webauthn-result", registration_result(%{error: :challenge_expired}))

      assert html =~ "The registration request expired."

      # A fresh challenge, then an unrecognized verifier error falls back to
      # the generic retry message.
      view
      |> form("#registration-form",
        registration: %{"email" => "expired@example.com", "name" => ""}
      )
      |> render_submit()

      html =
        render_hook(
          view,
          "webauthn-result",
          registration_result(%{error: :unknown_attestation_format})
        )

      assert html =~ "Passkey registration failed. Try again."
    end
  end

  describe "passkey sign-in (email-first)" do
    setup %{conn: conn} do
      user = user_fixture(email: "signin@example.com")
      credential = webauthn_credential_fixture(user, credential_id: "signin-cred", sign_count: 1)
      %{conn: conn, user: user, credential: credential}
    end

    test "lists the user's credentials in the challenge and signs in", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/sign-in")

      view
      |> form("#sign-in-form", sign_in: %{"email" => "signin@example.com"})
      |> render_submit()

      assert_push_event(view, "webauthn-authenticate", %{"publicKey" => public_key})
      assert public_key["rpId"] == "localhost"

      assert [%{"id" => allowed_id, "type" => "public-key"}] = public_key["allowCredentials"]
      assert allowed_id == Base.url_encode64("signin-cred", padding: false)

      html =
        render_hook(
          view,
          "webauthn-result",
          authentication_result("signin-cred", %{sign_count: 2})
        )

      assert %Session{strength: :passkey} = session_for(handoff_token(html))

      assert [%{sign_count: 2, last_used_at: %DateTime{}}] =
               Identity.list_webauthn_credentials(ctx.user)
    end

    test "unknown email or an email without passkeys yields a clear error", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/sign-in")

      html =
        view
        |> form("#sign-in-form", sign_in: %{"email" => "nobody@example.com"})
        |> render_submit()

      assert html =~ "No passkeys are registered"
      refute_push_event(view, "webauthn-authenticate", %{})
    end

    test "a decreasing sign counter is refused as a possible clone", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/sign-in")

      view
      |> form("#sign-in-form", sign_in: %{"email" => "signin@example.com"})
      |> render_submit()

      html =
        render_hook(
          view,
          "webauthn-result",
          authentication_result("signin-cred", %{sign_count: 0})
        )

      assert html =~ "may have been cloned"
      refute html =~ "session-handoff"
      assert [%{sign_count: 1}] = Identity.list_webauthn_credentials(ctx.user)
    end

    test "challenges are single-use on the sign-in side too", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/sign-in")

      view
      |> form("#sign-in-form", sign_in: %{"email" => "signin@example.com"})
      |> render_submit()

      render_hook(view, "webauthn-result", authentication_result("signin-cred", %{sign_count: 2}))

      html =
        render_hook(
          view,
          "webauthn-result",
          authentication_result("signin-cred", %{sign_count: 3})
        )

      assert html =~ "no longer valid"
    end

    test "a cancelled ceremony clears the challenge and shows the message", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/sign-in")

      view
      |> form("#sign-in-form", sign_in: %{"email" => "signin@example.com"})
      |> render_submit()

      html =
        render_hook(view, "webauthn-error", %{
          "message" => "The passkey request was cancelled or timed out."
        })

      assert html =~ "cancelled or timed out"

      html =
        render_hook(
          view,
          "webauthn-result",
          authentication_result("signin-cred", %{sign_count: 2})
        )

      assert html =~ "no longer valid"
    end
  end

  describe "TOTP step-up at sign-in (BC-US-146)" do
    setup %{conn: conn} do
      user = user_fixture(email: "totp@example.com")
      webauthn_credential_fixture(user, credential_id: "totp-cred", sign_count: 1)
      %{secret: secret} = enrolled_totp_fixture(user)
      %{conn: conn, user: user, secret: secret}
    end

    defp passkey_step(conn) do
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      view
      |> form("#sign-in-form", sign_in: %{"email" => "totp@example.com"})
      |> render_submit()

      html =
        render_hook(view, "webauthn-result", authentication_result("totp-cred", %{sign_count: 2}))

      {view, html}
    end

    test "passkey alone is not enough — a valid code upgrades the session strength", ctx do
      {view, html} = passkey_step(ctx.conn)

      assert html =~ "Authentication code"
      refute html =~ "session-handoff"

      html =
        view
        |> form("#totp-form", totp: %{"code" => NimbleTOTP.verification_code(ctx.secret)})
        |> render_submit()

      assert %Session{strength: :passkey_plus_totp} = session_for(handoff_token(html))
    end

    test "an invalid code is rejected and no session is created", ctx do
      {view, _html} = passkey_step(ctx.conn)

      html =
        view
        |> form("#totp-form", totp: %{"code" => "000000"})
        |> render_submit()

      assert html =~ "Invalid authentication code"
      assert Identity.list_active_sessions(ctx.user) == []
    end
  end

  describe "recovery-code sign-in" do
    setup %{conn: conn} do
      user = user_fixture(email: "recovery@example.com")
      webauthn_credential_fixture(user)
      %{recovery_codes: codes} = enrolled_totp_fixture(user)
      %{conn: conn, user: user, codes: codes}
    end

    test "consumes the code once and issues a recovery-strength session", ctx do
      [code | _rest] = ctx.codes
      {:ok, view, _html} = live(ctx.conn, ~p"/sign-in")

      render_click(view, "use_recovery_code", %{})

      html =
        view
        |> form("#recovery-form", recovery: %{"email" => "recovery@example.com", "code" => code})
        |> render_submit()

      assert %Session{strength: :recovery} = session_for(handoff_token(html))

      # The same code cannot be redeemed a second time.
      {:ok, view, _html} = live(ctx.conn, ~p"/sign-in")
      render_click(view, "use_recovery_code", %{})

      html =
        view
        |> form("#recovery-form", recovery: %{"email" => "recovery@example.com", "code" => code})
        |> render_submit()

      assert html =~ "Invalid email or recovery code"
    end

    test "wrong email/code combinations fail generically", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/sign-in")
      render_click(view, "use_recovery_code", %{})

      html =
        view
        |> form("#recovery-form",
          recovery: %{"email" => "recovery@example.com", "code" => "AAAA-AAAA-AAAA-AAAA"}
        )
        |> render_submit()

      assert html =~ "Invalid email or recovery code"

      html =
        view
        |> form("#recovery-form",
          recovery: %{"email" => "stranger@example.com", "code" => hd(ctx.codes)}
        )
        |> render_submit()

      assert html =~ "Invalid email or recovery code"
    end
  end

  describe "security page: passkeys" do
    test "requires authentication", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/security")
    end

    test "lists passkeys and adds a new one via the ceremony", %{conn: conn} do
      user = user_fixture(email: "sec@example.com")
      webauthn_credential_fixture(user, name: "First key")

      {:ok, view, html} = live(log_in(conn, user), ~p"/security")
      assert html =~ "First key"

      view
      |> form("#add-passkey-form", passkey: %{"name" => "Backup key"})
      |> render_submit()

      assert_push_event(view, "webauthn-register", %{"publicKey" => public_key})
      assert length(public_key["excludeCredentials"]) == 1

      html =
        render_hook(view, "webauthn-result", registration_result(%{credential_id: "backup"}))

      assert html =~ "Backup key"
      assert [_first, second] = Identity.list_webauthn_credentials(user)
      assert second.name == "Backup key"
    end

    test "refuses to revoke the last passkey without TOTP, allows it otherwise", %{conn: conn} do
      user = user_fixture(email: "guard@example.com")
      only_credential = webauthn_credential_fixture(user, name: "Only key")

      {:ok, view, _html} = live(log_in(conn, user), ~p"/security")

      html = render_click(view, "revoke_passkey", %{"id" => only_credential.id})
      assert html =~ "cannot remove your last passkey"
      assert [_credential] = Identity.list_webauthn_credentials(user)

      second = webauthn_credential_fixture(user, name: "Second key")
      {:ok, view, _html} = live(log_in(conn, user), ~p"/security")

      html = render_click(view, "revoke_passkey", %{"id" => second.id})
      assert html =~ "Passkey removed"
      assert [remaining] = Identity.list_webauthn_credentials(user)
      assert remaining.id == only_credential.id
    end
  end

  describe "security page: TOTP and recovery codes" do
    test "enroll → confirm shows recovery codes once; remove requires a code", %{conn: conn} do
      user = user_fixture(email: "sec-totp@example.com")
      webauthn_credential_fixture(user)

      {:ok, view, _html} = live(log_in(conn, user), ~p"/security")

      html = render_click(view, "enroll_totp", %{})
      assert html =~ "otpauth://totp/"

      %{"secret" => secret_b32} =
        Regex.named_captures(~r/id="totp-secret">(?<secret>[A-Z2-7]+)</, html)

      secret = Base.decode32!(secret_b32, padding: false)

      # Wrong code first: factor stays inactive.
      html =
        view
        |> form("#confirm-totp-form", totp: %{"code" => "000000"})
        |> render_submit()

      assert html =~ "not valid"
      refute Identity.totp_enabled?(user)

      html =
        view
        |> form("#confirm-totp-form", totp: %{"code" => NimbleTOTP.verification_code(secret)})
        |> render_submit()

      assert html =~ "Two-factor authentication enabled"
      assert html =~ "shown only once"
      assert Identity.totp_enabled?(user)
      assert length(Identity.list_recovery_codes(user)) == 10

      html = render_click(view, "dismiss_recovery_codes", %{})
      refute html =~ "shown only once"

      # Removal requires a valid current code (next timestep to avoid replay).
      html =
        view
        |> form("#remove-totp-form", totp: %{"code" => "000000"})
        |> render_submit()

      assert html =~ "valid current code is required"
      assert Identity.totp_enabled?(user)

      next_code =
        NimbleTOTP.verification_code(secret, time: System.os_time(:second) + 30)

      html =
        view
        |> form("#remove-totp-form", totp: %{"code" => next_code})
        |> render_submit()

      assert html =~ "Two-factor authentication disabled"
      refute Identity.totp_enabled?(user)
      assert Identity.list_recovery_codes(user) == []
    end

    test "regenerating recovery codes invalidates the previous batch", %{conn: conn} do
      user = user_fixture(email: "sec-codes@example.com")
      webauthn_credential_fixture(user)
      %{recovery_codes: [old_code | _rest]} = enrolled_totp_fixture(user)

      {:ok, view, _html} = live(log_in(conn, user), ~p"/security")

      html = render_click(view, "regenerate_recovery_codes", %{})
      assert html =~ "New recovery codes generated"
      assert html =~ "shown only once"

      assert {:error, :invalid_code} = Identity.consume_recovery_code(user, old_code)
      assert length(Identity.list_recovery_codes(user)) == 10
    end
  end

  describe "security page: sessions" do
    test "revokes a single session and all other sessions", %{conn: conn} do
      user = user_fixture(email: "sessions@example.com")
      webauthn_credential_fixture(user)

      {_other_token, other_session} = Identity.create_session(user, %{strength: :passkey})
      {_extra_token, extra_session} = Identity.create_session(user, %{strength: :passkey})

      conn = log_in(conn, user)
      {:ok, view, html} = live(conn, ~p"/security")

      assert html =~ "Current session"
      assert html =~ "session-#{other_session.id}"

      html = render_click(view, "revoke_session", %{"id" => other_session.id})
      assert html =~ "Session revoked"
      refute html =~ "session-#{other_session.id}"
      assert Repo.get!(Session, other_session.id).revoked_at

      html = render_click(view, "revoke_other_sessions", %{})
      assert html =~ "All other sessions were signed out"
      assert Repo.get!(Session, extra_session.id).revoked_at

      # The current session survives.
      assert [_current] = Identity.list_active_sessions(user)
    end

    test "the current session cannot be revoked from the list", %{conn: conn} do
      user = user_fixture(email: "current@example.com")
      webauthn_credential_fixture(user)

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/security")

      [current] = Identity.list_active_sessions(user)
      html = render_click(view, "revoke_session", %{"id" => current.id})

      assert html =~ "Use sign out"
      assert [_still_active] = Identity.list_active_sessions(user)
    end
  end

  describe "step-up helpers (recent authentication)" do
    test "recently_authenticated?/2 distinguishes fresh, stale, and revoked sessions" do
      alias BillingCoreWeb.UserAuth

      user = user_fixture()
      {_token, fresh} = Identity.create_session(user, %{strength: :passkey})
      assert UserAuth.recently_authenticated?(fresh)

      {_token, stale} =
        Identity.create_session(user, %{
          strength: :passkey,
          authenticated_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      refute UserAuth.recently_authenticated?(stale)
      assert UserAuth.recently_authenticated?(stale, 7200)

      {:ok, revoked} = Identity.revoke_session(fresh)
      refute UserAuth.recently_authenticated?(revoked)
      refute UserAuth.recently_authenticated?(nil)
    end
  end

  describe "session teardown" do
    test "DELETE /session revokes the server-side session", %{conn: conn} do
      user = user_fixture()
      {token, session} = Identity.create_session(user, %{strength: :passkey})

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_session_token" => token})
        |> delete(~p"/session")

      assert redirected_to(conn) == ~p"/sign-in"
      assert Repo.get!(Session, session.id).revoked_at
      assert Identity.get_user_by_session_token(token) == nil
    end
  end
end
