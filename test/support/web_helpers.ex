defmodule BillingCoreWeb.WebHelpers do
  @moduledoc """
  LiveView test helpers: signing a user into a `Phoenix.ConnTest` conn the
  same way `POST /session` does (opaque session token in the browser
  session; the server-side row carries everything else — SPEC §19.2).
  """

  alias BillingCore.Identity

  @doc "Puts a fresh session token for `user` into the conn's test session."
  def log_in_user(conn, user) do
    {token, _session} = Identity.create_session(user, %{})
    Phoenix.ConnTest.init_test_session(conn, %{"user_session_token" => token})
  end
end
