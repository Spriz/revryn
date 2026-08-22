defmodule BillingCoreWeb.SessionControllerTest do
  @moduledoc """
  HTTP session handoff (SPEC §19.2): the LiveView ceremony hands a one-time
  token to POST /session, which records request metadata and sets the
  cookie. The happy-path handoff from a real ceremony is covered in
  `test/workflows/authentication_test.exs`; this file pins the metadata and
  failure branches.
  """

  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.IdentityFixtures

  alias BillingCore.Identity

  describe "POST /session" do
    test "attaches request metadata to the session and redirects home", %{conn: conn} do
      user = user_fixture()
      {token, _session} = Identity.create_session(user)

      conn =
        conn
        |> put_req_header("user-agent", "test-browser/1.0")
        |> post(~p"/session", %{"session_token" => token})

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, "user_session_token") == token

      session = Identity.get_session_by_token(token)
      assert session.ip == "127.0.0.1"
      assert session.user_agent == "test-browser/1.0"
    end

    test "honors return_to", %{conn: conn} do
      user = user_fixture()
      {token, _session} = Identity.create_session(user)

      conn = post(conn, ~p"/session", %{"session_token" => token, "return_to" => "/security"})

      assert redirected_to(conn) == "/security"
    end

    test "records a nil user agent when the header is absent", %{conn: conn} do
      user = user_fixture()
      {token, _session} = Identity.create_session(user)

      conn = post(conn, ~p"/session", %{"session_token" => token})

      assert redirected_to(conn) == ~p"/"
      assert Identity.get_session_by_token(token).user_agent == nil
    end

    test "degrades to a nil ip for a transport without a peer address", %{conn: conn} do
      user = user_fixture()
      {token, _session} = Identity.create_session(user)

      # Plug always sets remote_ip for TCP requests (endpoint dispatch would
      # reset it), so the defensive non-tuple branch is exercised by calling
      # the action directly: exotic transports degrade instead of crashing.
      conn =
        %{conn | remote_ip: nil}
        |> Plug.Test.init_test_session(%{})
        |> BillingCoreWeb.SessionController.create(%{"session_token" => token})

      assert redirected_to(conn) == ~p"/"
      assert Identity.get_session_by_token(token).ip == nil
    end

    test "an unknown token never becomes an authenticated session", %{conn: conn} do
      bogus = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      conn = post(conn, ~p"/session", %{"session_token" => bogus})

      # The redirect happens (no oracle for token validity)…
      assert redirected_to(conn) == ~p"/"

      # …but the cookie does not authenticate anything: the dashboard mount
      # bounces straight back to sign-in.
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/sign-in"
    end
  end

  describe "DELETE /session" do
    # Teardown with an active session (revocation + redirect) is covered by
    # the "session teardown" workflow test; this pins idempotent sign-out.
    test "signing out without a session is safe", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> delete(~p"/session")

      assert redirected_to(conn) == ~p"/sign-in"
      assert get_session(conn, "user_session_token") == nil
    end
  end
end
