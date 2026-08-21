defmodule BillingCore.IdentityFixtures.StubVerifier do
  @moduledoc """
  Test-only `BillingCore.Identity.WebAuthn.Verifier` that skips the
  cryptographic attestation/assertion checks (fabricating real CBOR
  attestation objects in tests is not worthwhile — SPEC §23.10 real-browser
  coverage comes from Playwright with a virtual authenticator).

  Behavior is driven per call: tests encode an override map with
  `:erlang.term_to_binary/1` as the `attestation_object` (registration) or
  `authenticator_data` (authentication) argument. Recognized keys:
  `:credential_id`, `:cose_key`, `:sign_count`, `:backup_eligible`,
  `:backup_state`, and `:error` (forces that error). Non-term binaries fall
  back to defaults (fresh random credential id, fixed COSE key, count 0).

  Authentication still enforces the challenge allow-list, mirroring
  `Wax.authenticate/6`, so email-first credential listing stays testable.
  """

  @behaviour BillingCore.Identity.WebAuthn.Verifier

  @cose_key %{
    1 => 2,
    3 => -7,
    -1 => 1,
    -2 => :binary.copy(<<2>>, 32),
    -3 => :binary.copy(<<3>>, 32)
  }

  @doc "The fixed COSE key the stub reports for registrations."
  def cose_key, do: @cose_key

  @impl true
  def verify_registration(attestation_object, _client_data_json, _challenge) do
    overrides = decode_overrides(attestation_object)

    case overrides[:error] do
      nil ->
        {:ok,
         %{
           credential_id: overrides[:credential_id] || :crypto.strong_rand_bytes(16),
           cose_key: overrides[:cose_key] || @cose_key,
           sign_count: overrides[:sign_count] || 0,
           backup_eligible: overrides[:backup_eligible],
           backup_state: overrides[:backup_state]
         }}

      error ->
        {:error, error}
    end
  end

  @impl true
  def verify_authentication(credential_id, authenticator_data, _sig, _client_data, challenge) do
    allowed? =
      Enum.any?(challenge.allow_credentials, fn {allowed_id, _key} ->
        allowed_id == credential_id
      end)

    overrides = decode_overrides(authenticator_data)

    cond do
      not allowed? -> {:error, :credential_not_in_allow_list}
      error = overrides[:error] -> {:error, error}
      true -> {:ok, %{sign_count: overrides[:sign_count] || 0}}
    end
  end

  defp decode_overrides(binary) when is_binary(binary) do
    try do
      case :erlang.binary_to_term(binary) do
        %{} = overrides -> overrides
        _other -> %{}
      end
    rescue
      ArgumentError -> %{}
    end
  end

  defp decode_overrides(_other), do: %{}
end

defmodule BillingCore.IdentityFixtures do
  @moduledoc """
  Test fixtures for the `BillingCore.Identity` context.
  """

  alias BillingCore.Identity
  alias BillingCore.IdentityFixtures.StubVerifier
  alias BillingCore.Repo

  @doc "A globally unique, valid email address."
  def unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  @doc """
  Registers a user. Options: `:email`, `:platform_admin`, `:status`.
  """
  def user_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {:ok, user} = Identity.register_user(attrs[:email] || unique_email())

    overrides =
      attrs
      |> Map.take([:platform_admin, :status])
      |> Map.to_list()

    case overrides do
      [] -> user
      changes -> user |> Ecto.Changeset.change(changes) |> Repo.update!()
    end
  end

  @doc "Creates a session for `user`, returning `{plain_token, session}`."
  def session_fixture(user, attrs \\ %{}) do
    Identity.create_session(user, attrs)
  end

  @doc """
  ExUnit setup helper: routes WebAuthn verification through
  `BillingCore.IdentityFixtures.StubVerifier` for the duration of the test.
  Mutates global application env — use only in `async: false` test modules.
  """
  def stub_webauthn_verifier(_context \\ %{}) do
    previous = Application.get_env(:billing_core, :webauthn_verifier)
    Application.put_env(:billing_core, :webauthn_verifier, StubVerifier)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:billing_core, :webauthn_verifier)
        module -> Application.put_env(:billing_core, :webauthn_verifier, module)
      end
    end)

    :ok
  end

  @doc "Encodes a `StubVerifier` override map for use as a ceremony binary."
  def stub_webauthn_payload(overrides \\ %{}), do: :erlang.term_to_binary(Map.new(overrides))

  @doc "Base64url form of `stub_webauthn_payload/1`, as the JS hook would push it."
  def stub_webauthn_payload_b64(overrides \\ %{}) do
    Base.url_encode64(stub_webauthn_payload(overrides), padding: false)
  end

  @doc """
  Registers a WebAuthn credential for `user` directly (no ceremony).
  Options: `:credential_id`, `:name`, `:sign_count`, `:transports`,
  `:cose_key`.
  """
  def webauthn_credential_fixture(user, attrs \\ %{}) do
    attrs = Map.new(attrs)

    {:ok, credential} =
      Identity.register_webauthn_credential(user, %{
        credential_id: attrs[:credential_id] || :crypto.strong_rand_bytes(16),
        public_key: :erlang.term_to_binary(attrs[:cose_key] || StubVerifier.cose_key()),
        sign_count: attrs[:sign_count] || 0,
        name: attrs[:name] || "Test passkey",
        transports: attrs[:transports] || ["internal"]
      })

    credential
  end

  @doc """
  Enrolls and confirms a TOTP factor for `user` with a real NimbleTOTP
  code, returning `%{factor, secret, recovery_codes}`.

  Confirmation happens two periods in the past so the *current* timestep is
  still fresh for subsequent `Identity.verify_totp/2` calls in the test.
  """
  def enrolled_totp_fixture(user) do
    {:ok, %{secret: secret}} = Identity.enroll_totp(user)
    confirm_at = System.os_time(:second) - 60
    code = NimbleTOTP.verification_code(secret, time: confirm_at)

    {:ok, %{factor: factor, recovery_codes: recovery_codes}} =
      Identity.confirm_totp(user, code, at: confirm_at)

    %{factor: factor, secret: secret, recovery_codes: recovery_codes}
  end
end
