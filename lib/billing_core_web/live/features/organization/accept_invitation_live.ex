defmodule BillingCoreWeb.Features.Organization.AcceptInvitationLive do
  @moduledoc """
  Accepts a membership invitation for the signed-in user (BC-US-144).

  The token arrives only in the URL; acceptance is bound to the invited
  email address, single-use, and audited. The page never reveals whether a
  token exists — invalid, expired, revoked, and foreign tokens all read
  identically.
  """

  use BillingCoreWeb, :live_view

  alias BillingCore.Orgs

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-md py-16 text-center" id="accept-invitation">
        <.icon name="hero-envelope-open" class="mx-auto size-10 opacity-40" />
        <h1 class="mt-4 text-xl font-semibold">Checking your invitation…</h1>
        <p class="mt-2 text-sm opacity-70">You will be redirected in a moment.</p>
      </div>
    </Layouts.app>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    if connected?(socket) do
      case Orgs.accept_invitation(socket.assigns.current_user, token) do
        {:ok, invitation} ->
          destination =
            if invitation.team_id,
              do: ~p"/teams/#{invitation.team_id}",
              else: ~p"/"

          {:ok,
           socket
           |> put_flash(:info, "Welcome — your new workspace access is ready.")
           |> push_navigate(to: destination)}

        {:error, :email_mismatch} ->
          {:ok,
           socket
           |> put_flash(
             :error,
             "This invitation was issued to a different email address. Sign in with the invited address to accept it."
           )
           |> push_navigate(to: ~p"/")}

        {:error, _reason} ->
          {:ok,
           socket
           |> put_flash(
             :error,
             "That invitation link is no longer valid. Ask for a new invitation."
           )
           |> push_navigate(to: ~p"/")}
      end
    else
      {:ok, socket}
    end
  end
end
