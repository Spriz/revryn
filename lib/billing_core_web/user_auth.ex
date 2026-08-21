defmodule BillingCoreWeb.UserAuth do
  @moduledoc """
  Session-based authentication plug and LiveView mount hooks (SPEC §19.2).

  The browser session stores only the opaque session token; the server-side
  `sessions` row carries authentication strength/time, expiry, and revocation
  (INV-026/028). Organization/team scope is resolved per request from
  explicit selection — never from the user row (INV-024).
  """

  use BillingCoreWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias BillingCore.Identity

  @session_key "user_session_token"
  @recent_auth_max_age_seconds 600

  ## Plugs

  def fetch_current_user(conn, _opts) do
    with token when is_binary(token) <- get_session(conn, @session_key),
         user when not is_nil(user) <- Identity.get_user_by_session_token(token) do
      assign(conn, :current_user, user)
    else
      _ -> assign(conn, :current_user, nil)
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must sign in to access this page.")
      |> redirect(to: ~p"/sign-in")
      |> halt()
    end
  end

  @doc """
  Step-up guard for sensitive routes (SPEC §19.2): requires the server-side
  session to have been authenticated within the last
  #{@recent_auth_max_age_seconds} seconds, otherwise redirects to sign-in.
  """
  def require_recent_authentication(conn, opts) do
    max_age = Keyword.get(opts, :max_age_seconds, @recent_auth_max_age_seconds)

    if recently_authenticated?(current_session(conn), max_age) do
      conn
    else
      conn
      |> put_flash(:error, "Please sign in again to continue.")
      |> redirect(to: ~p"/sign-in")
      |> halt()
    end
  end

  @doc """
  Whether a server-side session's authentication is recent enough for
  sensitive (step-up) operations. `nil` sessions are never recent.
  """
  def recently_authenticated?(session, max_age_seconds \\ @recent_auth_max_age_seconds)

  def recently_authenticated?(%Identity.Session{} = session, max_age_seconds) do
    is_nil(session.revoked_at) and
      DateTime.diff(DateTime.utc_now(), session.authenticated_at, :second) <= max_age_seconds
  end

  def recently_authenticated?(nil, _max_age_seconds), do: false

  @doc """
  The server-side `%Identity.Session{}` behind the current request or a
  LiveView session map, or `nil`. Useful for showing/revoking the caller's
  own session and for step-up checks.
  """
  def current_session(%Plug.Conn{} = conn) do
    case get_session(conn, @session_key) do
      token when is_binary(token) -> Identity.get_session_by_token(token)
      _absent -> nil
    end
  end

  def current_session(%{} = live_session) do
    case live_session[@session_key] do
      token when is_binary(token) -> Identity.get_session_by_token(token)
      _absent -> nil
    end
  end

  @doc "Stores the session token and redirects after successful authentication."
  def log_in_user(conn, token, params \\ %{}) do
    conn
    |> renew_session()
    |> put_session(@session_key, token)
    |> redirect(to: params["return_to"] || ~p"/")
  end

  @doc "Revokes the server-side session and clears the browser session."
  def log_out_user(conn) do
    if token = get_session(conn, @session_key) do
      Identity.revoke_session_by_token(token)
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/sign-in")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  ## LiveView mount hooks

  def on_mount(:ensure_authenticated, _params, session, socket) do
    case fetch_user_from_session(session) do
      {:ok, user} ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}

      :error ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You must sign in to access this page.")
         |> Phoenix.LiveView.redirect(to: ~p"/sign-in")}
    end
  end

  def on_mount(:ensure_recent_authentication, _params, session, socket) do
    if recently_authenticated?(current_session(session)) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Please sign in again to continue.")
       |> Phoenix.LiveView.redirect(to: ~p"/sign-in")}
    end
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    user =
      case fetch_user_from_session(session) do
        {:ok, user} -> user
        :error -> nil
      end

    {:cont, Phoenix.Component.assign(socket, :current_user, user)}
  end

  defp fetch_user_from_session(session) do
    with token when is_binary(token) <- session[@session_key],
         user when not is_nil(user) <- Identity.get_user_by_session_token(token) do
      {:ok, user}
    else
      _ -> :error
    end
  end
end
