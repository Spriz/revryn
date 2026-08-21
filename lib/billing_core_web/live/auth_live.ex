defmodule BillingCoreWeb.AuthLive.WebAuthnSupport do
  @moduledoc """
  Shared helpers for the passkey LiveViews (BC-US-145): browser payloads
  for `navigator.credentials.create/get` and base64url codecs for the data
  the `WebAuthn` JS hook pushes back.

  Challenge lifecycle contract: each LiveView stores the `%Wax.Challenge{}`
  in an assign and *takes* it (clearing the assign) on the first
  verification attempt, making challenges single-use; expiry is enforced by
  `BillingCore.Identity.WebAuthn` (2 minutes).
  """

  alias BillingCore.Identity.WebauthnCredential

  @rp_name "Billing Core"

  @doc "PublicKeyCredentialCreationOptions for the JS hook (b64url-encoded binaries)."
  def creation_options(%Wax.Challenge{} = challenge, user, email, exclude_credentials) do
    %{
      "challenge" => encode_b64(challenge.bytes),
      "rp" => %{"id" => challenge.rp_id, "name" => @rp_name},
      "user" => %{"id" => encode_b64(user.id), "name" => email, "displayName" => email},
      "pubKeyCredParams" => [
        %{"type" => "public-key", "alg" => -7},
        %{"type" => "public-key", "alg" => -257}
      ],
      "timeout" => challenge.timeout * 1000,
      "attestation" => "none",
      "authenticatorSelection" => %{
        "residentKey" => "preferred",
        "userVerification" => challenge.user_verification
      },
      "excludeCredentials" =>
        Enum.map(exclude_credentials, fn %WebauthnCredential{} = credential ->
          %{"type" => "public-key", "id" => encode_b64(credential.credential_id)}
        end)
    }
  end

  @doc "PublicKeyCredentialRequestOptions for the JS hook (email-first allow list)."
  def request_options(%Wax.Challenge{} = challenge, credentials) do
    %{
      "challenge" => encode_b64(challenge.bytes),
      "rpId" => challenge.rp_id,
      "timeout" => challenge.timeout * 1000,
      "userVerification" => challenge.user_verification,
      "allowCredentials" =>
        Enum.map(credentials, fn %WebauthnCredential{} = credential ->
          %{
            "type" => "public-key",
            "id" => encode_b64(credential.credential_id),
            "transports" => credential.transports || []
          }
        end)
    }
  end

  @doc "Decodes the base64url-encoded fields of a hook result payload."
  def decode_result(params, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn {key, param}, {:ok, acc} ->
      with value when is_binary(value) <- Map.get(params, param),
           {:ok, decoded} <- Base.url_decode64(value, padding: false) do
        {:cont, {:ok, Map.put(acc, key, decoded)}}
      else
        _invalid -> {:halt, {:error, :malformed_response}}
      end
    end)
  end

  def encode_b64(binary), do: Base.url_encode64(binary, padding: false)
end

defmodule BillingCoreWeb.AuthLive.SignIn do
  @moduledoc """
  Passkey-first sign-in (BC-US-145/146, SPEC §19.2).

  Email-first flow: the user's non-revoked credential IDs become the
  challenge allow-list, so discoverable credentials are not required. After
  a verified assertion, users with an active TOTP factor must step up
  (session strength `passkey_plus_totp`); a recovery-code path issues
  `recovery`-strength sessions. The verified session token is handed to
  `POST /session` via `phx-trigger-action` so the cookie is set in a
  regular HTTP request.
  """

  use BillingCoreWeb, :live_view

  alias BillingCore.Identity
  alias BillingCoreWeb.AuthLive.WebAuthnSupport

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="sign-in" phx-hook="WebAuthn" class="mx-auto max-w-sm py-16 space-y-6">
        <.header>
          Sign in
          <:subtitle>Use a passkey — no password needed.</:subtitle>
        </.header>

        <p :if={!@supported} class="text-sm text-error" id="webauthn-unsupported">
          This browser does not support passkeys. Use a recovery code below or switch to a
          browser with WebAuthn support.
        </p>

        <p :if={@error} class="text-sm text-error" id="sign-in-error">{@error}</p>

        <div :if={@mode == :passkey && !@awaiting_totp && !@session_token}>
          <.form for={@email_form} id="sign-in-form" phx-submit="sign_in">
            <.input
              field={@email_form[:email]}
              type="email"
              label="Email"
              autocomplete="username webauthn"
              required
            />
            <.button variant="primary" class="mt-4 w-full" phx-disable-with="Waiting for passkey…">
              Sign in with a passkey
            </.button>
          </.form>

          <button type="button" class="btn btn-ghost btn-sm mt-4" phx-click="use_recovery_code">
            Use a recovery code instead
          </button>
        </div>

        <div :if={@mode == :passkey && @awaiting_totp && !@session_token} id="totp-step">
          <.form for={@totp_form} id="totp-form" phx-submit="verify_totp">
            <.input
              field={@totp_form[:code]}
              type="text"
              label="Authentication code"
              autocomplete="one-time-code"
              inputmode="numeric"
              required
            />
            <.button variant="primary" class="mt-4 w-full">Verify code</.button>
          </.form>
          <p class="mt-2 text-sm opacity-70">
            Enter the 6-digit code from your authenticator app.
          </p>
          <button type="button" class="btn btn-ghost btn-sm mt-4" phx-click="use_recovery_code">
            Use a recovery code instead
          </button>
        </div>

        <div :if={@mode == :recovery && !@session_token} id="recovery-step">
          <.form for={@recovery_form} id="recovery-form" phx-submit="recover">
            <.input
              field={@recovery_form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              required
            />
            <.input
              field={@recovery_form[:code]}
              type="text"
              label="Recovery code"
              autocomplete="off"
              required
            />
            <.button variant="primary" class="mt-4 w-full">Sign in with recovery code</.button>
          </.form>
          <p class="mt-2 text-sm opacity-70">Each recovery code can be used exactly once.</p>
          <button type="button" class="btn btn-ghost btn-sm mt-4" phx-click="use_passkey">
            Back to passkey sign-in
          </button>
        </div>

        <.form
          :if={@session_token}
          for={%{}}
          as={:handoff}
          id="session-handoff"
          action={~p"/session"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name="session_token" value={@session_token} />
          <p class="text-sm opacity-70">Signing you in…</p>
        </.form>

        <p class="text-sm opacity-70">
          New here? <.link navigate={~p"/register"} class="link">Create an account</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    if Identity.get_user_by_session_token(session["user_session_token"] || "") do
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:ok, reset(socket)}
    end
  end

  def handle_event("sign_in", %{"sign_in" => %{"email" => email}}, socket) do
    email = String.trim(email)
    user = Identity.get_user_by_email(email)

    credentials =
      if user && user.status == :active, do: Identity.list_webauthn_credentials(user), else: []

    case credentials do
      [] ->
        {:noreply, assign(socket, error: "No passkeys are registered for that email address.")}

      credentials ->
        challenge = Identity.authentication_challenge(credentials)

        {:noreply,
         socket
         |> assign(user: user, credentials: credentials, challenge: challenge, error: nil)
         |> push_event(
           "webauthn-authenticate",
           %{"publicKey" => WebAuthnSupport.request_options(challenge, credentials)}
         )}
    end
  end

  def handle_event("webauthn-result", params, socket) do
    {challenge, socket} = take_challenge(socket)

    with %Wax.Challenge{} <- challenge || {:error, :no_challenge},
         {:ok, decoded} <-
           WebAuthnSupport.decode_result(params, %{
             credential_id: "credentialId",
             authenticator_data: "authenticatorData",
             signature: "signature",
             client_data_json: "clientDataJSON"
           }),
         {:ok, _credential} <-
           Identity.verify_authentication(socket.assigns.user, challenge, decoded) do
      if Identity.totp_enabled?(socket.assigns.user) do
        {:noreply, assign(socket, awaiting_totp: true, error: nil)}
      else
        {:noreply, complete(socket, :passkey)}
      end
    else
      {:error, reason} -> {:noreply, assign(socket, error: authentication_error(reason))}
    end
  end

  def handle_event("webauthn-error", params, socket) do
    {_challenge, socket} = take_challenge(socket)
    message = params["message"] || "The passkey ceremony was cancelled or failed."
    {:noreply, assign(socket, error: message)}
  end

  def handle_event("webauthn-unsupported", _params, socket) do
    {:noreply, assign(socket, supported: false)}
  end

  def handle_event("verify_totp", %{"totp" => %{"code" => code}}, socket) do
    case Identity.verify_totp(socket.assigns.user, code) do
      :ok ->
        {:noreply, complete(socket, :passkey_plus_totp)}

      {:error, :code_already_used} ->
        {:noreply, assign(socket, error: "That code was already used — wait for the next one.")}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "Invalid authentication code.")}
    end
  end

  def handle_event("use_recovery_code", _params, socket) do
    {:noreply, socket |> reset() |> assign(mode: :recovery)}
  end

  def handle_event("use_passkey", _params, socket) do
    {:noreply, reset(socket)}
  end

  def handle_event("recover", %{"recovery" => %{"email" => email, "code" => code}}, socket) do
    user = Identity.get_user_by_email(String.trim(email))

    with %Identity.User{status: :active} <- user || :error,
         :ok <- Identity.consume_recovery_code(user, code) do
      {:noreply, socket |> assign(user: user) |> complete(:recovery)}
    else
      _invalid -> {:noreply, assign(socket, error: "Invalid email or recovery code.")}
    end
  end

  defp complete(socket, strength) do
    {token, _session} = Identity.create_session(socket.assigns.user, %{strength: strength})
    assign(socket, session_token: token, trigger_submit: true, error: nil)
  end

  defp take_challenge(socket) do
    {socket.assigns.challenge, assign(socket, :challenge, nil)}
  end

  defp reset(socket) do
    assign(socket,
      page_title: "Sign in",
      mode: :passkey,
      email_form: to_form(%{"email" => ""}, as: "sign_in"),
      totp_form: to_form(%{"code" => ""}, as: "totp"),
      recovery_form: to_form(%{"email" => "", "code" => ""}, as: "recovery"),
      user: nil,
      credentials: [],
      challenge: nil,
      awaiting_totp: false,
      session_token: nil,
      trigger_submit: false,
      error: nil,
      supported: true
    )
  end

  defp authentication_error(:no_challenge),
    do: "This sign-in attempt is no longer valid. Try again."

  defp authentication_error(:challenge_expired),
    do: "The sign-in request expired. Try again."

  defp authentication_error(:sign_count_regression),
    do:
      "This passkey reported an unexpected signature counter and may have been cloned. " <>
        "Sign-in was refused — review your passkeys."

  defp authentication_error(:unknown_credential),
    do: "That passkey is not registered for this account."

  defp authentication_error(:malformed_response),
    do: "The authenticator returned an unreadable response."

  defp authentication_error(_other), do: "Passkey verification failed. Try again."
end

defmodule BillingCoreWeb.AuthLive.Register do
  @moduledoc """
  Passkey-first registration (BC-US-145): email → server-side Wax
  registration challenge (single-use, 2-minute expiry) → authenticator
  attestation via the `WebAuthn` JS hook → credential storage → session
  handoff to `POST /session`.
  """

  use BillingCoreWeb, :live_view

  alias BillingCore.Identity
  alias BillingCoreWeb.AuthLive.WebAuthnSupport

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="register" phx-hook="WebAuthn" class="mx-auto max-w-sm py-16 space-y-6">
        <.header>
          Create your account
          <:subtitle>Your account is secured with a passkey instead of a password.</:subtitle>
        </.header>

        <p :if={!@supported} class="text-sm text-error" id="webauthn-unsupported">
          This browser does not support passkeys, which are required to create an account.
          Please use a browser with WebAuthn support.
        </p>

        <p :if={@error} class="text-sm text-error" id="register-error">{@error}</p>

        <div :if={!@session_token}>
          <.form for={@form} id="registration-form" phx-submit="register">
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              required
            />
            <.input
              field={@form[:name]}
              type="text"
              label="Passkey name (optional)"
              placeholder="e.g. MacBook Touch ID"
            />
            <.button
              variant="primary"
              class="mt-4 w-full"
              disabled={!@supported}
              phx-disable-with="Waiting for passkey…"
            >
              Create account with a passkey
            </.button>
          </.form>
        </div>

        <.form
          :if={@session_token}
          for={%{}}
          as={:handoff}
          id="session-handoff"
          action={~p"/session"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name="session_token" value={@session_token} />
          <p class="text-sm opacity-70">Account created — signing you in…</p>
        </.form>

        <p class="text-sm opacity-70">
          Already have an account? <.link navigate={~p"/sign-in"} class="link">Sign in</.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    if Identity.get_user_by_session_token(session["user_session_token"] || "") do
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:ok,
       assign(socket,
         page_title: "Create your account",
         form: to_form(%{"email" => "", "name" => ""}, as: "registration"),
         user: nil,
         email: nil,
         passkey_name: nil,
         challenge: nil,
         session_token: nil,
         trigger_submit: false,
         error: nil,
         supported: true
       )}
    end
  end

  def handle_event("register", %{"registration" => %{"email" => email} = params}, socket) do
    email = String.trim(email)

    case find_or_register_user(email) do
      {:ok, user} ->
        challenge = Identity.registration_challenge()

        {:noreply,
         socket
         |> assign(
           user: user,
           email: email,
           passkey_name: params["name"],
           challenge: challenge,
           error: nil
         )
         |> push_event(
           "webauthn-register",
           %{"publicKey" => WebAuthnSupport.creation_options(challenge, user, email, [])}
         )}

      {:error, message} ->
        {:noreply, assign(socket, error: message)}
    end
  end

  def handle_event("webauthn-result", params, socket) do
    {challenge, socket} = take_challenge(socket)

    with %Wax.Challenge{} <- challenge || {:error, :no_challenge},
         {:ok, decoded} <-
           WebAuthnSupport.decode_result(params, %{
             attestation_object: "attestationObject",
             client_data_json: "clientDataJSON"
           }),
         attrs =
           decoded
           |> Map.put(:transports, transports(params))
           |> Map.put(:name, socket.assigns.passkey_name),
         {:ok, _credential} <-
           Identity.verify_registration(socket.assigns.user, challenge, attrs) do
      {token, _session} = Identity.create_session(socket.assigns.user, %{strength: :passkey})
      {:noreply, assign(socket, session_token: token, trigger_submit: true, error: nil)}
    else
      {:error, reason} -> {:noreply, assign(socket, error: registration_error(reason))}
    end
  end

  def handle_event("webauthn-error", params, socket) do
    {_challenge, socket} = take_challenge(socket)
    message = params["message"] || "The passkey ceremony was cancelled or failed."
    {:noreply, assign(socket, error: message)}
  end

  def handle_event("webauthn-unsupported", _params, socket) do
    {:noreply, assign(socket, supported: false)}
  end

  defp find_or_register_user(email) do
    case Identity.register_user(email) do
      {:ok, user} ->
        {:ok, user}

      {:error, :email_taken} ->
        resume_registration(Identity.get_user_by_email(email))

      {:error, %Ecto.Changeset{}} ->
        {:error, "Enter a valid email address."}
    end
  end

  # An account that never completed passkey setup may resume registration;
  # anything with working credentials must go through sign-in.
  defp resume_registration(%Identity.User{status: :active} = user) do
    if Identity.list_webauthn_credentials(user) == [] and not Identity.totp_enabled?(user) do
      {:ok, user}
    else
      {:error, "An account with this email already exists. Sign in instead."}
    end
  end

  defp resume_registration(_user),
    do: {:error, "An account with this email already exists. Sign in instead."}

  defp transports(%{"transports" => transports}) when is_list(transports) do
    Enum.filter(transports, &is_binary/1)
  end

  defp transports(_params), do: []

  defp take_challenge(socket) do
    {socket.assigns.challenge, assign(socket, :challenge, nil)}
  end

  defp registration_error(:no_challenge),
    do: "This registration attempt is no longer valid. Try again."

  defp registration_error(:challenge_expired),
    do: "The registration request expired. Try again."

  defp registration_error(:credential_already_registered),
    do: "That passkey is already registered."

  defp registration_error(:malformed_response),
    do: "The authenticator returned an unreadable response."

  defp registration_error(_other), do: "Passkey registration failed. Try again."
end

defmodule BillingCoreWeb.AuthLive.Security do
  @moduledoc """
  Security self-service (BC-US-145/146): passkeys (add/revoke with a
  last-credential guard), TOTP (enroll/confirm/remove with proof of
  possession), recovery codes (regenerate, shown once), and active
  sessions (revoke one / all others).
  """

  use BillingCoreWeb, :live_view

  alias BillingCore.Identity
  alias BillingCoreWeb.AuthLive.WebAuthnSupport
  alias BillingCoreWeb.UserAuth

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="security" phx-hook="WebAuthn" class="mx-auto max-w-2xl py-8 space-y-10">
        <.header>
          Security
          <:subtitle>Passkeys, two-factor authentication, recovery codes, and sessions.</:subtitle>
        </.header>

        <section id="passkeys" class="space-y-4">
          <h2 class="text-lg font-semibold">Passkeys</h2>

          <table class="w-full text-sm">
            <thead>
              <tr class="text-left opacity-70">
                <th class="py-1 pr-4">Name</th>
                <th class="py-1 pr-4">Created</th>
                <th class="py-1 pr-4">Last used</th>
                <th class="py-1"></th>
              </tr>
            </thead>
            <tbody id="passkey-rows">
              <tr :for={passkey <- @passkeys} id={"passkey-#{passkey.id}"}>
                <td class="py-1 pr-4 font-medium">{passkey.name}</td>
                <td class="py-1 pr-4">{format_time(passkey.created_at)}</td>
                <td class="py-1 pr-4">{format_time(passkey.last_used_at) || "Never"}</td>
                <td class="py-1 text-right">
                  <.button
                    phx-click="revoke_passkey"
                    phx-value-id={passkey.id}
                    data-confirm="Remove this passkey? You will no longer be able to sign in with it."
                  >
                    Remove
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>

          <.form for={@passkey_form} id="add-passkey-form" phx-submit="add_passkey">
            <div class="flex items-end gap-2">
              <.input
                field={@passkey_form[:name]}
                type="text"
                label="New passkey name"
                placeholder="e.g. YubiKey 5"
              />
              <.button variant="primary" disabled={!@supported}>Add passkey</.button>
            </div>
          </.form>
          <p :if={!@supported} class="text-sm text-error">
            This browser does not support passkeys.
          </p>
        </section>

        <section id="totp" class="space-y-4">
          <h2 class="text-lg font-semibold">Two-factor authentication (TOTP)</h2>

          <div :if={@totp_factor} class="space-y-4">
            <p class="text-sm">
              Enabled since {format_time(@totp_factor.activated_at)}. Sign-in requires a code
              from your authenticator app.
            </p>
            <.form for={@totp_remove_form} id="remove-totp-form" phx-submit="remove_totp">
              <div class="flex items-end gap-2">
                <.input
                  field={@totp_remove_form[:code]}
                  type="text"
                  label="Current code (required to disable)"
                  autocomplete="one-time-code"
                  inputmode="numeric"
                />
                <.button data-confirm="Disable two-factor authentication? Your recovery codes will also be invalidated.">
                  Disable TOTP
                </.button>
              </div>
            </.form>
          </div>

          <div :if={!@totp_factor && @totp_enrollment} class="space-y-4" id="totp-enrollment">
            <p class="text-sm">
              Add this secret to your authenticator app, then confirm with a generated code:
            </p>
            <p class="text-sm">
              <code class="break-all" id="totp-otpauth-uri">{@totp_enrollment.otpauth_uri}</code>
            </p>
            <p class="text-sm">
              Manual entry key:
              <code id="totp-secret">{Base.encode32(@totp_enrollment.secret, padding: false)}</code>
            </p>
            <.form for={@totp_confirm_form} id="confirm-totp-form" phx-submit="confirm_totp">
              <div class="flex items-end gap-2">
                <.input
                  field={@totp_confirm_form[:code]}
                  type="text"
                  label="Code from your app"
                  autocomplete="one-time-code"
                  inputmode="numeric"
                />
                <.button variant="primary">Confirm</.button>
              </div>
            </.form>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_totp_enrollment">
              Cancel enrollment
            </button>
          </div>

          <div :if={!@totp_factor && !@totp_enrollment}>
            <p class="text-sm opacity-70">
              Not enabled. TOTP adds a second factor for sign-in and sensitive actions.
            </p>
            <.button variant="primary" class="mt-2" phx-click="enroll_totp">Enable TOTP</.button>
          </div>
        </section>

        <section id="recovery-codes" class="space-y-4">
          <h2 class="text-lg font-semibold">Recovery codes</h2>

          <div :if={@revealed_recovery_codes} id="revealed-recovery-codes" class="space-y-2">
            <p class="text-sm text-error">
              Store these recovery codes now — they are shown only once. Each works exactly once.
            </p>
            <ul class="grid grid-cols-2 gap-1 font-mono text-sm">
              <li :for={code <- @revealed_recovery_codes}>{code}</li>
            </ul>
            <.button phx-click="dismiss_recovery_codes">I have saved these codes</.button>
          </div>

          <div :if={!@revealed_recovery_codes}>
            <p class="text-sm opacity-70">
              {@recovery_codes_remaining} unused recovery {if @recovery_codes_remaining == 1,
                do: "code",
                else: "codes"} remaining.
            </p>
            <.button
              :if={@totp_factor}
              class="mt-2"
              phx-click="regenerate_recovery_codes"
              data-confirm="Generate new recovery codes? Your current codes will stop working."
            >
              Regenerate recovery codes
            </.button>
            <p :if={!@totp_factor} class="mt-2 text-sm opacity-70">
              Recovery codes are issued when two-factor authentication is enabled.
            </p>
          </div>
        </section>

        <section id="sessions" class="space-y-4">
          <h2 class="text-lg font-semibold">Active sessions</h2>

          <table class="w-full text-sm">
            <thead>
              <tr class="text-left opacity-70">
                <th class="py-1 pr-4">Signed in</th>
                <th class="py-1 pr-4">Strength</th>
                <th class="py-1 pr-4">Device</th>
                <th class="py-1"></th>
              </tr>
            </thead>
            <tbody id="session-rows">
              <tr :for={session <- @sessions} id={"session-#{session.id}"}>
                <td class="py-1 pr-4">{format_time(session.authenticated_at)}</td>
                <td class="py-1 pr-4">{session.strength}</td>
                <td class="py-1 pr-4">
                  {session.user_agent || "Unknown device"}{if session.ip, do: " (#{session.ip})"}
                </td>
                <td class="py-1 text-right">
                  <span :if={session.id == @current_session_id} class="text-xs opacity-70">
                    Current session
                  </span>
                  <.button
                    :if={session.id != @current_session_id}
                    phx-click="revoke_session"
                    phx-value-id={session.id}
                    data-confirm="Sign this session out?"
                  >
                    Revoke
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>

          <.button
            :if={length(@sessions) > 1}
            phx-click="revoke_other_sessions"
            data-confirm="Sign out all other sessions?"
          >
            Sign out all other sessions
          </.button>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, session, socket) do
    current_session = UserAuth.current_session(session)

    {:ok,
     socket
     |> assign(
       page_title: "Security",
       current_session_id: current_session && current_session.id,
       passkey_form: to_form(%{"name" => ""}, as: "passkey"),
       totp_confirm_form: to_form(%{"code" => ""}, as: "totp"),
       totp_remove_form: to_form(%{"code" => ""}, as: "totp"),
       totp_enrollment: nil,
       revealed_recovery_codes: nil,
       challenge: nil,
       pending_passkey_name: nil,
       supported: true
     )
     |> refresh()}
  end

  ## Passkeys

  def handle_event("add_passkey", %{"passkey" => %{"name" => name}}, socket) do
    user = socket.assigns.current_user
    email = primary_email(user)
    challenge = Identity.registration_challenge()

    {:noreply,
     socket
     |> assign(challenge: challenge, pending_passkey_name: name)
     |> push_event(
       "webauthn-register",
       %{
         "publicKey" =>
           WebAuthnSupport.creation_options(challenge, user, email, socket.assigns.passkeys)
       }
     )}
  end

  def handle_event("webauthn-result", params, socket) do
    {challenge, socket} = take_challenge(socket)

    with %Wax.Challenge{} <- challenge || {:error, :no_challenge},
         {:ok, decoded} <-
           WebAuthnSupport.decode_result(params, %{
             attestation_object: "attestationObject",
             client_data_json: "clientDataJSON"
           }),
         attrs =
           decoded
           |> Map.put(:transports, params["transports"] || [])
           |> Map.put(:name, socket.assigns.pending_passkey_name),
         {:ok, credential} <-
           Identity.verify_registration(socket.assigns.current_user, challenge, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Passkey \"#{credential.name}\" added.")
       |> refresh()}
    else
      {:error, :challenge_expired} ->
        {:noreply, put_flash(socket, :error, "The passkey request expired. Try again.")}

      {:error, :credential_already_registered} ->
        {:noreply, put_flash(socket, :error, "That passkey is already registered.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Adding the passkey failed. Try again.")}
    end
  end

  def handle_event("webauthn-error", params, socket) do
    {_challenge, socket} = take_challenge(socket)
    message = params["message"] || "The passkey ceremony was cancelled or failed."
    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_event("webauthn-unsupported", _params, socket) do
    {:noreply, assign(socket, supported: false)}
  end

  def handle_event("revoke_passkey", %{"id" => id}, socket) do
    with %{} = credential <- Enum.find(socket.assigns.passkeys, &(&1.id == id)),
         {:ok, _revoked} <- Identity.revoke_passkey(socket.assigns.current_user, credential) do
      {:noreply, socket |> put_flash(:info, "Passkey removed.") |> refresh()}
    else
      {:error, :last_credential} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You cannot remove your last passkey while two-factor authentication is disabled."
         )}

      _not_found ->
        {:noreply, put_flash(socket, :error, "Passkey not found.")}
    end
  end

  ## TOTP

  def handle_event("enroll_totp", _params, socket) do
    case Identity.enroll_totp(socket.assigns.current_user) do
      {:ok, enrollment} ->
        {:noreply, assign(socket, totp_enrollment: enrollment)}

      {:error, :already_enabled} ->
        {:noreply, put_flash(socket, :error, "Two-factor authentication is already enabled.")}
    end
  end

  def handle_event("cancel_totp_enrollment", _params, socket) do
    {:noreply, assign(socket, totp_enrollment: nil)}
  end

  def handle_event("confirm_totp", %{"totp" => %{"code" => code}}, socket) do
    case Identity.confirm_totp(socket.assigns.current_user, code) do
      {:ok, %{recovery_codes: codes}} ->
        {:noreply,
         socket
         |> assign(totp_enrollment: nil, revealed_recovery_codes: codes)
         |> put_flash(:info, "Two-factor authentication enabled.")
         |> refresh()}

      {:error, :invalid_code} ->
        {:noreply, put_flash(socket, :error, "That code is not valid. Try the next one.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Confirming two-factor authentication failed.")}
    end
  end

  def handle_event("remove_totp", %{"totp" => %{"code" => code}}, socket) do
    case Identity.remove_totp(socket.assigns.current_user, code) do
      {:ok, _factor} ->
        {:noreply,
         socket
         |> assign(revealed_recovery_codes: nil)
         |> put_flash(:info, "Two-factor authentication disabled.")
         |> refresh()}

      {:error, :code_already_used} ->
        {:noreply,
         put_flash(socket, :error, "That code was already used — wait for the next one.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "A valid current code is required to disable TOTP.")}
    end
  end

  ## Recovery codes

  def handle_event("regenerate_recovery_codes", _params, socket) do
    case Identity.generate_recovery_codes(socket.assigns.current_user) do
      {:ok, %{codes: codes}} ->
        {:noreply,
         socket
         |> assign(revealed_recovery_codes: codes)
         |> put_flash(:info, "New recovery codes generated. Previous codes no longer work.")
         |> refresh()}

      {:error, :totp_not_enabled} ->
        {:noreply,
         put_flash(socket, :error, "Enable two-factor authentication to get recovery codes.")}
    end
  end

  def handle_event("dismiss_recovery_codes", _params, socket) do
    {:noreply, assign(socket, revealed_recovery_codes: nil)}
  end

  ## Sessions

  def handle_event("revoke_session", %{"id" => id}, socket) do
    cond do
      id == socket.assigns.current_session_id ->
        {:noreply, put_flash(socket, :error, "Use sign out to end your current session.")}

      session = Identity.get_user_session(socket.assigns.current_user, id) ->
        {:ok, _revoked} = Identity.revoke_session(session)
        {:noreply, socket |> put_flash(:info, "Session revoked.") |> refresh()}

      true ->
        {:noreply, put_flash(socket, :error, "Session not found.")}
    end
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    {:ok, _revoked} =
      Identity.revoke_other_sessions(
        socket.assigns.current_user,
        socket.assigns.current_session_id
      )

    {:noreply, socket |> put_flash(:info, "All other sessions were signed out.") |> refresh()}
  end

  ## Helpers

  defp refresh(socket) do
    user = socket.assigns.current_user

    assign(socket,
      passkeys: Identity.list_webauthn_credentials(user),
      totp_factor: Identity.get_active_totp_factor(user),
      recovery_codes_remaining: length(Identity.list_recovery_codes(user)),
      sessions: Identity.list_active_sessions(user)
    )
  end

  defp take_challenge(socket) do
    {socket.assigns.challenge, assign(socket, :challenge, nil)}
  end

  defp primary_email(user) do
    Identity.get_primary_email(user) || "account"
  end

  defp format_time(nil), do: nil

  defp format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end

defmodule BillingCoreWeb.DashboardLive do
  @moduledoc """
  Authenticated landing page: the user's teams grouped by organization as
  entry points into the team-scoped product UI (SPEC §13.4).
  """

  use BillingCoreWeb, :live_view

  alias BillingCore.Orgs

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-3xl py-8 space-y-8">
        <.header>
          Your teams
          <:subtitle>Pick a team to work in — every billing view is team-scoped.</:subtitle>
        </.header>

        <.empty_state :if={@org_groups == []} id="no-teams">
          You are not a member of any team yet. Ask an organization owner to invite you.
        </.empty_state>

        <section :for={{organization, teams} <- @org_groups} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-60">
            {organization.name}
          </h2>
          <ul id={"org-#{organization.id}-teams"} class="grid gap-2 sm:grid-cols-2">
            <li :for={team <- teams}>
              <.link
                navigate={~p"/teams/#{team.id}"}
                id={"team-link-#{team.id}"}
                class="flex items-center justify-between rounded-lg border border-base-300 px-4 py-3 hover:border-primary hover:bg-base-200 transition-colors"
              >
                <span>
                  <span class="block font-medium">{team.name}</span>
                  <span class="block text-xs opacity-60">
                    {team.base_currency} · {team.time_zone}
                  </span>
                </span>
                <.icon name="hero-arrow-right" class="size-4 opacity-40" />
              </.link>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    org_groups =
      socket.assigns.current_user
      |> Orgs.list_user_teams()
      |> Enum.chunk_by(& &1.organization_id)
      |> Enum.map(fn [first | _] = teams -> {first.organization, teams} end)

    {:ok, assign(socket, page_title: "Teams", org_groups: org_groups)}
  end
end
