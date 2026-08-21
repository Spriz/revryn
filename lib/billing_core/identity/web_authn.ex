defmodule BillingCore.Identity.WebAuthn do
  @moduledoc """
  WebAuthn/FIDO2 passkey ceremonies (SPEC §19.2, BC-US-145).

  Challenges are built from deployment configuration
  (`config :billing_core, :webauthn` — `:origin` and `:rp_id`, validated
  exactly) and are short-lived (#{2} minutes). Single-use is enforced by the
  caller: the sign-in/registration LiveViews hold the challenge in an assign
  and clear it on the first verification attempt.

  The cryptographic verification step is isolated behind the
  `BillingCore.Identity.WebAuthn.Verifier` behaviour so integration tests
  can substitute a stub without fabricating CBOR attestation objects:

      config :billing_core, :webauthn_verifier, MyStubVerifier

  The default (`BillingCore.Identity.WebAuthn.WaxVerifier`) delegates to
  `Wax.register/3` and `Wax.authenticate/6`, which perform full origin,
  RP ID, challenge, signature, and user-presence validation.
  """

  import Ecto.Query

  alias BillingCore.Identity
  alias BillingCore.Identity.{User, WebauthnCredential}
  alias BillingCore.Repo

  @challenge_timeout_seconds 120

  defmodule Verifier do
    @moduledoc """
    Boundary for the cryptographic WebAuthn verification step.

    Production uses `BillingCore.Identity.WebAuthn.WaxVerifier`; tests may
    configure a stub via `config :billing_core, :webauthn_verifier`.
    """

    @type registration_result :: %{
            required(:credential_id) => binary(),
            required(:cose_key) => map(),
            required(:sign_count) => non_neg_integer(),
            optional(:backup_eligible) => boolean() | nil,
            optional(:backup_state) => boolean() | nil
          }

    @callback verify_registration(
                attestation_object :: binary(),
                client_data_json :: binary(),
                challenge :: Wax.Challenge.t()
              ) :: {:ok, registration_result()} | {:error, term()}

    @callback verify_authentication(
                credential_id :: binary(),
                authenticator_data :: binary(),
                signature :: binary(),
                client_data_json :: binary(),
                challenge :: Wax.Challenge.t()
              ) :: {:ok, %{sign_count: non_neg_integer()}} | {:error, term()}
  end

  defmodule WaxVerifier do
    @moduledoc "Default `Verifier` backed by the `Wax` library."

    @behaviour BillingCore.Identity.WebAuthn.Verifier

    @impl true
    def verify_registration(attestation_object, client_data_json, challenge) do
      case Wax.register(attestation_object, client_data_json, challenge) do
        {:ok, {auth_data, _attestation_result}} ->
          attested = auth_data.attested_credential_data

          {:ok,
           %{
             credential_id: attested.credential_id,
             cose_key: attested.credential_public_key,
             sign_count: auth_data.sign_count,
             backup_eligible: auth_data.flag_backup_eligible,
             backup_state: auth_data.flag_credential_backed_up
           }}

        {:error, _reason} = error ->
          error
      end
    end

    @impl true
    def verify_authentication(credential_id, authenticator_data, signature, client_data, chall) do
      case Wax.authenticate(credential_id, authenticator_data, signature, client_data, chall) do
        {:ok, auth_data} -> {:ok, %{sign_count: auth_data.sign_count}}
        {:error, _reason} = error -> error
      end
    end
  end

  ## Challenges

  @doc """
  Builds a short-lived registration challenge from deployment config.

  `opts` are merged onto the defaults (`user_verification: "preferred"`,
  `attestation: "none"`, timeout #{@challenge_timeout_seconds}s).
  """
  @spec registration_challenge(Keyword.t()) :: Wax.Challenge.t()
  def registration_challenge(opts \\ []) do
    [attestation: "none"]
    |> Keyword.merge(default_challenge_opts())
    |> Keyword.merge(opts)
    |> Wax.new_registration_challenge()
  end

  @doc """
  Builds an authentication challenge allowing exactly `credentials`
  (email-first flow: the caller looks the user's credentials up by email).
  """
  @spec authentication_challenge([WebauthnCredential.t()], Keyword.t()) :: Wax.Challenge.t()
  def authentication_challenge(credentials, opts \\ []) when is_list(credentials) do
    allow_credentials =
      Enum.map(credentials, fn credential ->
        {credential.credential_id, deserialize_cose_key(credential.public_key)}
      end)

    default_challenge_opts()
    |> Keyword.merge(opts)
    |> Keyword.put(:allow_credentials, allow_credentials)
    |> Wax.new_authentication_challenge()
  end

  ## Ceremony completion

  @doc """
  Verifies a registration (attestation) response and persists the credential.

  `attrs` requires `:attestation_object` and `:client_data_json` (raw
  binaries, already base64url-decoded) and accepts `:name` and
  `:transports`.

  Returns `{:ok, credential}`, `{:error, :challenge_expired}`,
  `{:error, :credential_already_registered}` (credential IDs are globally
  unique), or the verifier's `{:error, reason}`.
  """
  @spec verify_registration(User.t(), Wax.Challenge.t(), map()) ::
          {:ok, WebauthnCredential.t()} | {:error, term()}
  def verify_registration(%User{} = user, %Wax.Challenge{} = challenge, attrs) do
    attrs = Map.new(attrs)

    with :ok <- ensure_fresh(challenge),
         {:ok, result} <-
           verifier().verify_registration(
             Map.fetch!(attrs, :attestation_object),
             Map.fetch!(attrs, :client_data_json),
             challenge
           ) do
      user
      |> Identity.register_webauthn_credential(%{
        credential_id: result.credential_id,
        public_key: serialize_cose_key(result.cose_key),
        sign_count: result.sign_count,
        backup_eligible: Map.get(result, :backup_eligible),
        backup_state: Map.get(result, :backup_state),
        transports: attrs[:transports],
        name: credential_name(attrs[:name])
      })
      |> case do
        {:ok, credential} ->
          {:ok, credential}

        {:error, %Ecto.Changeset{} = changeset} ->
          if unique_error?(changeset, :credential_id),
            do: {:error, :credential_already_registered},
            else: {:error, changeset}
      end
    end
  end

  @doc """
  Verifies an authentication (assertion) response for one of `user`'s
  non-revoked credentials.

  `attrs` requires `:credential_id`, `:authenticator_data`, `:signature`,
  and `:client_data_json` as raw binaries.

  A non-increasing signature counter (when counters are in use) is rejected
  as a possible authenticator clone — the credential is left untouched and
  `{:error, :sign_count_regression}` is returned. On success the stored
  counter and `last_used_at` are updated.
  """
  @spec verify_authentication(User.t(), Wax.Challenge.t(), map()) ::
          {:ok, WebauthnCredential.t()} | {:error, term()}
  def verify_authentication(%User{} = user, %Wax.Challenge{} = challenge, attrs) do
    attrs = Map.new(attrs)
    credential_id = Map.fetch!(attrs, :credential_id)

    with :ok <- ensure_fresh(challenge),
         {:ok, credential} <- fetch_active_credential(user, credential_id),
         {:ok, %{sign_count: new_sign_count}} <-
           verifier().verify_authentication(
             credential_id,
             Map.fetch!(attrs, :authenticator_data),
             Map.fetch!(attrs, :signature),
             Map.fetch!(attrs, :client_data_json),
             challenge
           ),
         :ok <- check_sign_count(credential, new_sign_count) do
      {:ok, touch_credential(credential, new_sign_count)}
    end
  end

  @doc "Deserializes the stored COSE public key of a credential."
  @spec cose_key(WebauthnCredential.t()) :: map()
  def cose_key(%WebauthnCredential{public_key: public_key}),
    do: deserialize_cose_key(public_key)

  @doc false
  @spec serialize_cose_key(map()) :: binary()
  def serialize_cose_key(cose_key) when is_map(cose_key), do: :erlang.term_to_binary(cose_key)

  @doc false
  @spec deserialize_cose_key(binary()) :: map()
  def deserialize_cose_key(binary) when is_binary(binary),
    do: :erlang.binary_to_term(binary, [:safe])

  @doc "The configured challenge validity, in seconds."
  @spec challenge_timeout_seconds() :: pos_integer()
  def challenge_timeout_seconds, do: @challenge_timeout_seconds

  ## Internal helpers

  defp default_challenge_opts do
    config = Application.fetch_env!(:billing_core, :webauthn)

    [
      origin: Keyword.fetch!(config, :origin),
      rp_id: Keyword.fetch!(config, :rp_id),
      user_verification: "preferred",
      timeout: @challenge_timeout_seconds
    ]
  end

  # Wax enforces expiry itself, but the verifier boundary is swappable in
  # tests, so freshness is (re)checked here to keep it a hard guarantee.
  defp ensure_fresh(%Wax.Challenge{issued_at: issued_at, timeout: timeout}) do
    if System.system_time(:second) - issued_at < timeout do
      :ok
    else
      {:error, :challenge_expired}
    end
  end

  defp fetch_active_credential(%User{id: user_id}, credential_id) do
    Repo.one(
      from c in WebauthnCredential,
        where:
          c.user_id == ^user_id and c.credential_id == ^credential_id and
            is_nil(c.revoked_at)
    )
    |> case do
      nil -> {:error, :unknown_credential}
      credential -> {:ok, credential}
    end
  end

  # Both counters at zero means the authenticator does not implement a
  # signature counter; otherwise the new value must strictly increase.
  defp check_sign_count(%WebauthnCredential{sign_count: 0}, 0), do: :ok
  defp check_sign_count(%WebauthnCredential{sign_count: stored}, new) when new > stored, do: :ok
  defp check_sign_count(%WebauthnCredential{}, _new), do: {:error, :sign_count_regression}

  defp touch_credential(%WebauthnCredential{} = credential, new_sign_count) do
    credential
    |> Ecto.Changeset.change(sign_count: new_sign_count, last_used_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp credential_name(name) when is_binary(name) and name != "", do: name
  defp credential_name(_other), do: "Passkey"

  defp verifier do
    Application.get_env(:billing_core, :webauthn_verifier, WaxVerifier)
  end

  defp unique_error?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_msg, meta}} -> meta[:constraint] == :unique
      _other -> false
    end)
  end
end
