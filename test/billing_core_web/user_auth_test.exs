defmodule BillingCoreWeb.UserAuthTest do
  @moduledoc """
  Session plug and LiveView mount-hook behavior (SPEC §19.2, INV-026/028):
  token resolution to users, unauthenticated/stale-session redirects,
  session establishment and teardown, and the `on_mount` hooks called
  directly. Full-stack ceremonies live in
  `test/workflows/authentication_test.exs`.
  """

  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.IdentityFixtures

  alias BillingCore.Identity
  alias BillingCore.Identity.Session
  alias BillingCore.Repo
  alias BillingCoreWeb.UserAuth
  alias Phoenix.LiveView

  @session_key "user_session_token"

  setup %{conn: conn} do
    %{conn: Plug.Test.init_test_session(conn, %{}), user: user_fixture()}
  end

  defp put_token(conn, token), do: Plug.Test.init_test_session(conn, %{@session_key => token})

  defp build_socket do
    %LiveView.Socket{
      endpoint: BillingCoreWeb.Endpoint,
      assigns: %{__changed__: %{}, flash: %{}}
    }
  end

  describe "fetch_current_user/2" do
    test "assigns the user behind a valid session token", %{conn: conn, user: user} do
      {token, _session} = Identity.create_session(user)

      conn = conn |> put_token(token) |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user.id == user.id
    end

    test "assigns nil when the session carries no token", %{conn: conn} do
      conn = UserAuth.fetch_current_user(conn, [])

      assert conn.assigns.current_user == nil
    end

    test "assigns nil for an unknown token", %{conn: conn} do
      other = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      conn = conn |> put_token(other) |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end

    test "assigns nil for an expired session", %{conn: conn, user: user} do
      {token, _session} =
        Identity.create_session(user, %{
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      conn = conn |> put_token(token) |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end

    test "assigns nil for a revoked session", %{conn: conn, user: user} do
      {token, session} = Identity.create_session(user)
      {:ok, _revoked} = Identity.revoke_session(session)

      conn = conn |> put_token(token) |> UserAuth.fetch_current_user([])

      assert conn.assigns.current_user == nil
    end
  end

  describe "require_authenticated_user/2" do
    test "redirects to sign-in and halts when unauthenticated", %{conn: conn} do
      conn =
        conn
        |> Phoenix.Controller.fetch_flash()
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/sign-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must sign in to access this page."
    end

    test "passes the connection through when a user is assigned", %{conn: conn, user: user} do
      conn =
        conn
        |> assign(:current_user, user)
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "require_recent_authentication/2 (step-up guard)" do
    test "passes a freshly authenticated session", %{conn: conn, user: user} do
      {token, _session} = Identity.create_session(user)

      conn = conn |> put_token(token) |> UserAuth.require_recent_authentication([])

      refute conn.halted
    end

    test "redirects a stale session to sign-in", %{conn: conn, user: user} do
      {token, _session} =
        Identity.create_session(user, %{
          authenticated_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      conn =
        conn
        |> put_token(token)
        |> Phoenix.Controller.fetch_flash()
        |> UserAuth.require_recent_authentication([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/sign-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Please sign in again to continue."
    end

    test "redirects when there is no session at all", %{conn: conn} do
      conn =
        conn
        |> Phoenix.Controller.fetch_flash()
        |> UserAuth.require_recent_authentication([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/sign-in"
    end

    test "honors a custom :max_age_seconds", %{conn: conn, user: user} do
      {token, _session} =
        Identity.create_session(user, %{
          authenticated_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      conn =
        conn
        |> put_token(token)
        |> UserAuth.require_recent_authentication(max_age_seconds: 7200)

      refute conn.halted
    end
  end

  describe "current_session/1" do
    test "resolves the server-side session from a conn", %{conn: conn, user: user} do
      {token, session} = Identity.create_session(user)

      assert %Session{id: id} = UserAuth.current_session(put_token(conn, token))
      assert id == session.id
    end

    test "returns nil for a conn without a token", %{conn: conn} do
      assert UserAuth.current_session(conn) == nil
    end

    test "resolves the server-side session from a LiveView session map", %{user: user} do
      {token, session} = Identity.create_session(user)

      assert %Session{id: id} = UserAuth.current_session(%{@session_key => token})
      assert id == session.id
    end

    test "returns nil for a LiveView session map without a token" do
      assert UserAuth.current_session(%{}) == nil
      assert UserAuth.current_session(%{@session_key => nil}) == nil
    end
  end

  describe "log_in_user/3" do
    test "renews the session, stores the token, and redirects home", %{conn: conn, user: user} do
      {token, _session} = Identity.create_session(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{"stale" => "value"})
        |> UserAuth.log_in_user(token)

      assert get_session(conn, @session_key) == token
      # renew_session/1 clears everything that was in the session before.
      assert get_session(conn, "stale") == nil
      assert redirected_to(conn) == ~p"/"
    end

    test "honors a return_to param", %{conn: conn, user: user} do
      {token, _session} = Identity.create_session(user)

      conn = UserAuth.log_in_user(conn, token, %{"return_to" => "/security"})

      assert redirected_to(conn) == "/security"
    end
  end

  describe "log_out_user/1" do
    test "revokes the server-side session and clears the browser session", %{
      conn: conn,
      user: user
    } do
      {token, session} = Identity.create_session(user)

      conn = conn |> put_token(token) |> UserAuth.log_out_user()

      assert get_session(conn, @session_key) == nil
      assert redirected_to(conn) == ~p"/sign-in"
      assert Repo.get!(Session, session.id).revoked_at
    end

    test "signs out safely when no token is present", %{conn: conn} do
      conn = UserAuth.log_out_user(conn)

      assert redirected_to(conn) == ~p"/sign-in"
    end
  end

  describe "on_mount :ensure_authenticated" do
    test "continues with the current user assigned", %{user: user} do
      {token, _session} = Identity.create_session(user)

      assert {:cont, socket} =
               UserAuth.on_mount(
                 :ensure_authenticated,
                 %{},
                 %{@session_key => token},
                 build_socket()
               )

      assert socket.assigns.current_user.id == user.id
    end

    test "halts and redirects to sign-in without a valid token" do
      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_authenticated, %{}, %{}, build_socket())

      assert {:redirect, %{to: "/sign-in"}} = socket.redirected

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "You must sign in to access this page."
    end
  end

  describe "on_mount :ensure_recent_authentication" do
    test "continues for a fresh session", %{user: user} do
      {token, _session} = Identity.create_session(user)

      assert {:cont, _socket} =
               UserAuth.on_mount(
                 :ensure_recent_authentication,
                 %{},
                 %{@session_key => token},
                 build_socket()
               )
    end

    test "halts and redirects for a stale session", %{user: user} do
      {token, _session} =
        Identity.create_session(user, %{
          authenticated_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      assert {:halt, socket} =
               UserAuth.on_mount(
                 :ensure_recent_authentication,
                 %{},
                 %{@session_key => token},
                 build_socket()
               )

      assert {:redirect, %{to: "/sign-in"}} = socket.redirected

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Please sign in again to continue."
    end
  end

  describe "on_mount :mount_current_user" do
    test "assigns the user when the token resolves", %{user: user} do
      {token, _session} = Identity.create_session(user)

      assert {:cont, socket} =
               UserAuth.on_mount(
                 :mount_current_user,
                 %{},
                 %{@session_key => token},
                 build_socket()
               )

      assert socket.assigns.current_user.id == user.id
    end

    test "assigns nil — and still continues — without a token" do
      assert {:cont, socket} =
               UserAuth.on_mount(:mount_current_user, %{}, %{}, build_socket())

      assert socket.assigns.current_user == nil
    end
  end
end
