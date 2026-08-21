defmodule BillingCoreWeb.SessionController do
  @moduledoc """
  Session establishment/teardown. The WebAuthn ceremony completes in the
  sign-in LiveView, which hands a one-time session token to this controller
  so the cookie is set in a regular HTTP request (SPEC §19.2).
  """

  use BillingCoreWeb, :controller

  alias BillingCore.Identity
  alias BillingCoreWeb.UserAuth

  def create(conn, %{"session_token" => token} = params) do
    # The ceremony ran over the LiveView socket, so the session row has no
    # request metadata yet — record it here where conn data is available.
    Identity.attach_session_metadata(token, %{
      ip: format_ip(conn.remote_ip),
      user_agent: first_header(conn, "user-agent")
    })

    UserAuth.log_in_user(conn, token, params)
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(_other), do: nil

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end
end
