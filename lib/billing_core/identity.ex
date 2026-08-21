defmodule BillingCore.Identity do
  @moduledoc """
  Global identity context (SPEC §6.3, §9.1.1, §13.3, §19.2).

  Owns the global `users` table, email addresses, authentication credential
  storage (WebAuthn passkeys, TOTP factors, recovery codes, OIDC federated
  identities), revocable server-side sessions, and the authentication
  ceremonies on top of that material: WebAuthn registration/authentication
  (delegated to `BillingCore.Identity.WebAuthn`), TOTP
  enrollment/step-up with replay protection (`BillingCore.Identity.Totp`),
  and single-use recovery codes.

  Deliberately out of scope here: authorization — that is membership-based
  and lives in `BillingCore.Orgs` (`resolve_scope/3`). Identity
  repositories are global and are never passed a team as an authorization
  shortcut (SPEC §13.4).

  Credential and session revocations are audited via `BillingCore.Audit`
  inside the same transaction as the change.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Repo}

  alias BillingCore.Identity.{
    FederatedIdentity,
    RecoveryCode,
    Session,
    Totp,
    TotpFactor,
    User,
    UserEmail,
    WebAuthn,
    WebauthnCredential
  }

  alias Ecto.Multi

  @session_token_bytes 32
  @session_validity_days 14
  @recovery_code_count 10
  @recovery_code_bytes 10

  ## Users and emails

  @doc """
  Registers a new global user with `email` as primary, unverified address.

  Returns `{:ok, user}` with `:emails` preloaded, `{:error, :email_taken}`
  when the address already belongs to a user (case-insensitive), or
  `{:error, changeset}` for an invalid address.
  """
  @spec register_user(String.t()) ::
          {:ok, User.t()} | {:error, :email_taken} | {:error, Ecto.Changeset.t()}
  def register_user(email) when is_binary(email) do
    Multi.new()
    |> Multi.insert(:user, User.changeset(%User{}, %{}))
    |> Multi.insert(:email, fn %{user: user} ->
      %UserEmail{user_id: user.id}
      |> UserEmail.changeset(%{email: email, primary: true})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, email: user_email}} ->
        {:ok, %{user | emails: [user_email]}}

      {:error, :email, changeset, _changes} ->
        if unique_error?(changeset, :email) do
          {:error, :email_taken}
        else
          {:error, changeset}
        end
    end
  end

  @doc "Fetches the user owning `email` (case-insensitive), or `nil`."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.one(
      from u in User,
        join: e in UserEmail,
        on: e.user_id == u.id,
        where: e.email == ^email
    )
  end

  @doc "Fetches a user by ID, raising if absent."
  @spec get_user!(Ecto.UUID.t()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc "The primary email address of `user`, or `nil`."
  @spec get_primary_email(User.t()) :: String.t() | nil
  def get_primary_email(%User{} = user) do
    Repo.one(
      from e in UserEmail,
        where: e.user_id == ^user.id and e.primary == true,
        select: e.email
    )
  end

  @doc """
  Marks an email address as verified (idempotent).

  Accepts a `%UserEmail{}` or the address itself; returns
  `{:error, :not_found}` for an unknown address.
  """
  @spec verify_email(UserEmail.t() | String.t()) ::
          {:ok, UserEmail.t()} | {:error, :not_found}
  def verify_email(%UserEmail{verified_at: %DateTime{}} = user_email), do: {:ok, user_email}

  def verify_email(%UserEmail{} = user_email) do
    user_email
    |> Ecto.Changeset.change(verified_at: now())
    |> Repo.update()
  end

  def verify_email(email) when is_binary(email) do
    case Repo.get_by(UserEmail, email: email) do
      nil -> {:error, :not_found}
      user_email -> verify_email(user_email)
    end
  end

  ## Sessions

  @doc """
  Creates a session for `user` and returns `{plain_token, session}`.

  The opaque token is #{@session_token_bytes} random bytes (returned
  URL-base64 encoded); only its SHA-256 hash is persisted. `attrs` may set
  `:strength` (default `:passkey`), `:authenticated_at` (default now),
  `:expires_at` (default now + #{@session_validity_days} days), `:ip`, and
  `:user_agent`.
  """
  @spec create_session(User.t(), map()) :: {String.t(), Session.t()}
  def create_session(%User{} = user, attrs \\ %{}) do
    token = :crypto.strong_rand_bytes(@session_token_bytes)

    attrs =
      Map.merge(
        %{
          authenticated_at: now(),
          strength: :passkey,
          expires_at: DateTime.add(now(), @session_validity_days, :day)
        },
        Map.new(attrs)
      )

    session =
      %Session{user_id: user.id, token_hash: hash_token(token)}
      |> Session.changeset(attrs)
      |> Repo.insert!()

    {encode_token(token), session}
  end

  @doc """
  Resolves a plain session token to its active user.

  Returns `nil` when the token is malformed or unknown, the session is
  expired or revoked, or the user is disabled.
  """
  @spec get_user_by_session_token(String.t()) :: User.t() | nil
  def get_user_by_session_token(plain_token) when is_binary(plain_token) do
    case decode_token(plain_token) do
      {:ok, token} ->
        now = now()

        Repo.one(
          from u in User,
            join: s in Session,
            on: s.user_id == u.id,
            where: s.token_hash == ^hash_token(token),
            where: is_nil(s.revoked_at) and s.expires_at > ^now,
            where: u.status == :active
        )

      :error ->
        nil
    end
  end

  @doc "Fetches the session for a plain token regardless of validity, or `nil`."
  @spec get_session_by_token(String.t()) :: Session.t() | nil
  def get_session_by_token(plain_token) when is_binary(plain_token) do
    case decode_token(plain_token) do
      {:ok, token} -> Repo.get_by(Session, token_hash: hash_token(token))
      :error -> nil
    end
  end

  @doc "Revokes the session belonging to a plain token (idempotent no-op when absent)."
  @spec revoke_session_by_token(String.t()) :: :ok
  def revoke_session_by_token(plain_token) when is_binary(plain_token) do
    case get_session_by_token(plain_token) do
      nil -> :ok
      session -> tap(:ok, fn _ -> revoke_session(session) end)
    end
  end

  @doc "Revokes a session (idempotent). Audited as `identity.session.revoked`."
  @spec revoke_session(Session.t()) :: {:ok, Session.t()}
  def revoke_session(%Session{revoked_at: %DateTime{}} = session), do: {:ok, session}

  def revoke_session(%Session{} = session) do
    {:ok, revoked} =
      Repo.transaction(fn ->
        {:ok, revoked} =
          session
          |> Ecto.Changeset.change(revoked_at: now())
          |> Repo.update()

        audit_session_revoked!(revoked)
        revoked
      end)

    {:ok, revoked}
  end

  @doc """
  Revokes every active session of `user`, auditing each revocation.

  Returns `{:ok, revoked_sessions}`.
  """
  @spec revoke_all_sessions(User.t()) :: {:ok, [Session.t()]}
  def revoke_all_sessions(%User{} = user) do
    Repo.transaction(fn ->
      sessions =
        Repo.all(
          from s in Session,
            where: s.user_id == ^user.id and is_nil(s.revoked_at),
            lock: "FOR UPDATE"
        )

      for session <- sessions do
        {:ok, revoked} =
          session
          |> Ecto.Changeset.change(revoked_at: now())
          |> Repo.update()

        audit_session_revoked!(revoked)
        revoked
      end
    end)
  end

  @doc "Lists the active (unexpired, unrevoked) sessions of `user`, newest first."
  @spec list_active_sessions(User.t()) :: [Session.t()]
  def list_active_sessions(%User{} = user) do
    now = now()

    Repo.all(
      from s in Session,
        where: s.user_id == ^user.id and is_nil(s.revoked_at) and s.expires_at > ^now,
        order_by: [desc: s.created_at]
    )
  end

  @doc "Fetches a session by id, scoped to `user`. Returns `nil` when absent."
  @spec get_user_session(User.t(), Ecto.UUID.t()) :: Session.t() | nil
  def get_user_session(%User{} = user, session_id) do
    Repo.get_by(Session, id: session_id, user_id: user.id)
  end

  @doc """
  Revokes every active session of `user` except `keep_session_id`
  ("sign out other devices"). Each revocation is audited.
  """
  @spec revoke_other_sessions(User.t(), Ecto.UUID.t()) :: {:ok, [Session.t()]}
  def revoke_other_sessions(%User{} = user, keep_session_id) do
    Repo.transaction(fn ->
      sessions =
        Repo.all(
          from s in Session,
            where: s.user_id == ^user.id and is_nil(s.revoked_at) and s.id != ^keep_session_id,
            lock: "FOR UPDATE"
        )

      for session <- sessions do
        {:ok, revoked} =
          session
          |> Ecto.Changeset.change(revoked_at: now())
          |> Repo.update()

        audit_session_revoked!(revoked)
        revoked
      end
    end)
  end

  @doc """
  Records request metadata (`:ip`, `:user_agent`) on the session behind a
  plain token — used by the HTTP handoff after a LiveView-side ceremony,
  where connect info is unavailable. No-op for unknown tokens.
  """
  @spec attach_session_metadata(String.t(), map()) :: :ok
  def attach_session_metadata(plain_token, metadata) when is_binary(plain_token) do
    case get_session_by_token(plain_token) do
      nil ->
        :ok

      session ->
        session
        |> Session.changeset(Map.take(Map.new(metadata), [:ip, :user_agent]))
        |> Repo.update()

        :ok
    end
  end

  ## WebAuthn ceremonies (BC-US-145)

  @doc "See `BillingCore.Identity.WebAuthn.registration_challenge/1`."
  defdelegate registration_challenge(opts \\ []), to: WebAuthn

  @doc "See `BillingCore.Identity.WebAuthn.authentication_challenge/2`."
  defdelegate authentication_challenge(credentials, opts \\ []), to: WebAuthn

  @doc "See `BillingCore.Identity.WebAuthn.verify_registration/3`."
  defdelegate verify_registration(user, challenge, attrs), to: WebAuthn

  @doc "See `BillingCore.Identity.WebAuthn.verify_authentication/3`."
  defdelegate verify_authentication(user, challenge, attrs), to: WebAuthn

  @doc """
  Revokes a passkey on behalf of its owner, refusing to remove the final
  active passkey while no active TOTP factor exists (the account would be
  left without any way to authenticate).

  Returns `{:ok, credential}`, `{:error, :not_found}`, or
  `{:error, :last_credential}`.
  """
  @spec revoke_passkey(User.t(), WebauthnCredential.t()) ::
          {:ok, WebauthnCredential.t()} | {:error, :not_found | :last_credential}
  def revoke_passkey(%User{} = user, %WebauthnCredential{} = credential) do
    cond do
      credential.user_id != user.id ->
        {:error, :not_found}

      not is_nil(credential.revoked_at) ->
        {:ok, credential}

      last_active_credential?(user, credential) and is_nil(get_active_totp_factor(user)) ->
        {:error, :last_credential}

      true ->
        revoke_webauthn_credential(credential)
    end
  end

  defp last_active_credential?(user, credential) do
    case list_webauthn_credentials(user) do
      [%WebauthnCredential{id: only_id}] -> only_id == credential.id
      _zero_or_many -> false
    end
  end

  ## WebAuthn credentials (persistence only — no ceremony logic)

  @doc "Persists a registered WebAuthn credential for `user`."
  @spec register_webauthn_credential(User.t(), map()) ::
          {:ok, WebauthnCredential.t()} | {:error, Ecto.Changeset.t()}
  def register_webauthn_credential(%User{} = user, attrs) do
    %WebauthnCredential{user_id: user.id}
    |> WebauthnCredential.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Lists the non-revoked WebAuthn credentials of `user`."
  @spec list_webauthn_credentials(User.t()) :: [WebauthnCredential.t()]
  def list_webauthn_credentials(%User{} = user) do
    Repo.all(
      from c in WebauthnCredential,
        where: c.user_id == ^user.id and is_nil(c.revoked_at),
        order_by: [asc: c.created_at]
    )
  end

  @doc """
  Revokes a WebAuthn credential (idempotent). Audited as
  `identity.webauthn_credential.revoked`.
  """
  @spec revoke_webauthn_credential(WebauthnCredential.t()) :: {:ok, WebauthnCredential.t()}
  def revoke_webauthn_credential(%WebauthnCredential{revoked_at: %DateTime{}} = credential),
    do: {:ok, credential}

  def revoke_webauthn_credential(%WebauthnCredential{} = credential) do
    revoke_credential(credential, "identity.webauthn_credential.revoked", "webauthn_credential")
  end

  ## TOTP factors (persistence only — no ceremony logic)

  @doc "Persists a TOTP factor envelope for `user` (not yet activated)."
  @spec create_totp_factor(User.t(), map()) ::
          {:ok, TotpFactor.t()} | {:error, Ecto.Changeset.t()}
  def create_totp_factor(%User{} = user, attrs) do
    %TotpFactor{user_id: user.id}
    |> TotpFactor.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Lists the non-revoked TOTP factors of `user`."
  @spec list_totp_factors(User.t()) :: [TotpFactor.t()]
  def list_totp_factors(%User{} = user) do
    Repo.all(
      from f in TotpFactor,
        where: f.user_id == ^user.id and is_nil(f.revoked_at),
        order_by: [asc: f.created_at]
    )
  end

  @doc """
  Revokes a TOTP factor (idempotent). Audited as
  `identity.totp_factor.revoked`.
  """
  @spec revoke_totp_factor(TotpFactor.t()) :: {:ok, TotpFactor.t()}
  def revoke_totp_factor(%TotpFactor{revoked_at: %DateTime{}} = factor), do: {:ok, factor}

  def revoke_totp_factor(%TotpFactor{} = factor) do
    revoke_credential(factor, "identity.totp_factor.revoked", "totp_factor")
  end

  ## TOTP ceremonies (BC-US-146)

  @doc "The active (confirmed, unrevoked) TOTP factor of `user`, or `nil`."
  @spec get_active_totp_factor(User.t()) :: TotpFactor.t() | nil
  def get_active_totp_factor(%User{} = user) do
    Repo.one(
      from f in TotpFactor,
        where: f.user_id == ^user.id and is_nil(f.revoked_at) and not is_nil(f.activated_at),
        limit: 1
    )
  end

  @doc "The pending (unconfirmed) TOTP enrollment of `user`, or `nil`."
  @spec get_pending_totp_factor(User.t()) :: TotpFactor.t() | nil
  def get_pending_totp_factor(%User{} = user) do
    Repo.one(
      from f in TotpFactor,
        where: f.user_id == ^user.id and is_nil(f.revoked_at) and is_nil(f.activated_at),
        order_by: [desc: f.created_at],
        limit: 1
    )
  end

  @doc "Whether `user` has an active TOTP factor."
  @spec totp_enabled?(User.t()) :: boolean()
  def totp_enabled?(%User{} = user), do: get_active_totp_factor(user) != nil

  @doc """
  Starts TOTP enrollment: generates a secret, stores it envelope-encrypted
  and inactive, and returns `{:ok, %{factor, secret, otpauth_uri}}` — the
  plaintext secret exists only in this return value, for QR/manual entry.

  Replaces any previous unconfirmed enrollment. Returns
  `{:error, :already_enabled}` when an active factor exists.
  """
  @spec enroll_totp(User.t()) ::
          {:ok, %{factor: TotpFactor.t(), secret: binary(), otpauth_uri: String.t()}}
          | {:error, :already_enabled}
  def enroll_totp(%User{} = user) do
    if totp_enabled?(user) do
      {:error, :already_enabled}
    else
      secret = Totp.generate_secret()

      {:ok, factor} =
        Repo.transaction(fn ->
          Repo.delete_all(
            from f in TotpFactor,
              where: f.user_id == ^user.id and is_nil(f.activated_at) and is_nil(f.revoked_at)
          )

          {:ok, factor} =
            create_totp_factor(user, %{secret_ciphertext: Totp.encrypt_secret(secret)})

          factor
        end)

      {:ok,
       %{
         factor: factor,
         secret: secret,
         otpauth_uri: Totp.otpauth_uri(secret, totp_account_label(user))
       }}
    end
  end

  @doc """
  Confirms a pending TOTP enrollment with a freshly generated code.

  On success the factor is activated, the accepted timestep is recorded
  (replay guard), and a fresh batch of #{@recovery_code_count} recovery
  codes is generated (recovery codes are mandatory alongside TOTP —
  SPEC §19.2). Returns `{:ok, %{factor, recovery_codes}}` with the
  plaintext codes, shown exactly once.

  `opts` may carry `:at` (Unix seconds) for clock injection in tests.
  """
  @spec confirm_totp(User.t(), String.t(), Keyword.t()) ::
          {:ok, %{factor: TotpFactor.t(), recovery_codes: [String.t()]}}
          | {:error, :not_enrolled | :invalid_code | :decryption_failed}
  def confirm_totp(%User{} = user, code, opts \\ []) when is_binary(code) do
    at = Keyword.get(opts, :at, System.os_time(:second))

    with %TotpFactor{} = factor <- get_pending_totp_factor(user) || {:error, :not_enrolled},
         {:ok, secret} <- Totp.decrypt_secret(factor.secret_ciphertext),
         {:ok, timestep} <- match_totp_code(secret, code, at) do
      {:ok, result} =
        Repo.transaction(fn ->
          factor =
            factor
            |> Ecto.Changeset.change(activated_at: now(), last_timestep: timestep)
            |> Repo.update!()

          %{codes: codes} = regenerate_recovery_codes!(user)
          %{factor: factor, recovery_codes: codes}
        end)

      {:ok, result}
    end
  end

  @doc """
  Verifies a TOTP code against the active factor for step-up (SPEC §19.2).

  Accepts ±1 period of clock drift. Replay is rejected: the accepted
  timestep must be later than the last accepted one, which is advanced
  atomically. `opts` may carry `:at` (Unix seconds) for tests.
  """
  @spec verify_totp(User.t(), String.t(), Keyword.t()) ::
          :ok
          | {:error, :not_enabled | :invalid_code | :code_already_used | :decryption_failed}
  def verify_totp(%User{} = user, code, opts \\ []) when is_binary(code) do
    at = Keyword.get(opts, :at, System.os_time(:second))

    with %TotpFactor{} = factor <- get_active_totp_factor(user) || {:error, :not_enabled},
         {:ok, secret} <- Totp.decrypt_secret(factor.secret_ciphertext),
         {:ok, timestep} <- match_totp_code(secret, code, at) do
      advance_query =
        from f in TotpFactor,
          where:
            f.id == ^factor.id and is_nil(f.revoked_at) and
              (is_nil(f.last_timestep) or f.last_timestep < ^timestep)

      case Repo.update_all(advance_query, set: [last_timestep: timestep]) do
        {1, _} -> :ok
        {0, _} -> {:error, :code_already_used}
      end
    end
  end

  @doc """
  Removes the active TOTP factor. Requires a valid current code as proof of
  possession.

  In the same transaction, outstanding recovery codes are invalidated (they
  exist only alongside TOTP) and sessions whose strength depended on the
  factor (`passkey_plus_totp`, `recovery`) are revoked (BC-US-146). All
  revocations are audited.
  """
  @spec remove_totp(User.t(), String.t(), Keyword.t()) ::
          {:ok, TotpFactor.t()}
          | {:error, :not_enabled | :invalid_code | :code_already_used | :decryption_failed}
  def remove_totp(%User{} = user, code, opts \\ []) when is_binary(code) do
    with :ok <- verify_totp(user, code, opts),
         %TotpFactor{} = factor <- get_active_totp_factor(user) || {:error, :not_enabled} do
      {:ok, revoked} =
        Repo.transaction(fn ->
          {:ok, revoked} = revoke_totp_factor(factor)

          Repo.update_all(
            from(c in RecoveryCode, where: c.user_id == ^user.id and is_nil(c.consumed_at)),
            set: [consumed_at: now()]
          )

          revoke_step_up_sessions!(user)
          revoked
        end)

      {:ok, revoked}
    end
  end

  defp match_totp_code(secret, code, at) do
    case Totp.matching_timestep(secret, code, at) do
      {:ok, timestep} -> {:ok, timestep}
      :error -> {:error, :invalid_code}
    end
  end

  defp revoke_step_up_sessions!(%User{} = user) do
    sessions =
      Repo.all(
        from s in Session,
          where:
            s.user_id == ^user.id and is_nil(s.revoked_at) and
              s.strength in [:passkey_plus_totp, :recovery],
          lock: "FOR UPDATE"
      )

    for session <- sessions do
      {:ok, revoked} =
        session
        |> Ecto.Changeset.change(revoked_at: now())
        |> Repo.update()

      audit_session_revoked!(revoked)
      revoked
    end
  end

  defp totp_account_label(%User{} = user) do
    get_primary_email(user) || user.id
  end

  ## Recovery code ceremonies (BC-US-146)

  @doc """
  Generates a fresh batch of #{@recovery_code_count} recovery codes,
  invalidating any unconsumed codes from previous batches.

  Only the SHA-256 hashes are stored; the plaintext codes in the returned
  `%{codes: codes, batch: batch}` are shown exactly once. Requires an
  active TOTP factor (recovery codes exist as its companion recovery path).
  """
  @spec generate_recovery_codes(User.t()) ::
          {:ok, %{codes: [String.t()], batch: pos_integer()}} | {:error, :totp_not_enabled}
  def generate_recovery_codes(%User{} = user) do
    if totp_enabled?(user) do
      {:ok, result} = Repo.transaction(fn -> regenerate_recovery_codes!(user) end)
      {:ok, result}
    else
      {:error, :totp_not_enabled}
    end
  end

  @doc """
  Consumes a recovery code: single-use, set `consumed_at` atomically so a
  code can never be redeemed twice (audited as
  `identity.recovery_code.consumed`).
  """
  @spec consume_recovery_code(User.t(), String.t()) :: :ok | {:error, :invalid_code}
  def consume_recovery_code(%User{} = user, code) when is_binary(code) do
    code_hash = hash_recovery_code(code)

    {:ok, result} =
      Repo.transaction(fn ->
        consume_query =
          from c in RecoveryCode,
            where: c.user_id == ^user.id and c.code_hash == ^code_hash and is_nil(c.consumed_at),
            select: c.id

        case Repo.update_all(consume_query, set: [consumed_at: now()]) do
          {1, [code_id]} ->
            Audit.record!(:system, "identity.recovery_code.consumed",
              aggregate: {"recovery_code", code_id},
              payload: %{user_id: user.id}
            )

            :ok

          {0, _} ->
            {:error, :invalid_code}
        end
      end)

    result
  end

  defp regenerate_recovery_codes!(%User{} = user) do
    Repo.delete_all(
      from c in RecoveryCode, where: c.user_id == ^user.id and is_nil(c.consumed_at)
    )

    batch =
      (Repo.one(from c in RecoveryCode, where: c.user_id == ^user.id, select: max(c.batch)) ||
         0) + 1

    codes = for _n <- 1..@recovery_code_count, do: generate_recovery_code()
    {:ok, _stored} = insert_recovery_codes(user, Enum.map(codes, &hash_recovery_code/1), batch)
    %{codes: codes, batch: batch}
  end

  defp generate_recovery_code do
    @recovery_code_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
    |> String.replace(~r/(.{4})(?=.)/, "\\1-")
  end

  defp hash_recovery_code(code) do
    normalized = code |> String.replace(~r/[\s-]/, "") |> String.upcase()
    :sha256 |> :crypto.hash(normalized) |> Base.encode16(case: :lower)
  end

  ## Recovery codes (persistence only)

  @doc """
  Stores a batch of pre-hashed recovery codes for `user`.

  `code_hashes` are one-way hashes computed by the caller — plaintext codes
  never reach this context. Returns `{:ok, codes}`.
  """
  @spec insert_recovery_codes(User.t(), [String.t()], pos_integer()) ::
          {:ok, [RecoveryCode.t()]}
  def insert_recovery_codes(%User{} = user, code_hashes, batch)
      when is_list(code_hashes) and is_integer(batch) and batch >= 1 do
    Repo.transaction(fn ->
      for code_hash <- code_hashes do
        %RecoveryCode{user_id: user.id}
        |> RecoveryCode.changeset(%{code_hash: code_hash, batch: batch})
        |> Repo.insert!()
      end
    end)
  end

  @doc "Lists the unconsumed recovery codes of `user`, optionally by batch."
  @spec list_recovery_codes(User.t(), pos_integer() | nil) :: [RecoveryCode.t()]
  def list_recovery_codes(%User{} = user, batch \\ nil) do
    query =
      from c in RecoveryCode,
        where: c.user_id == ^user.id and is_nil(c.consumed_at),
        order_by: [asc: c.created_at]

    query = if batch, do: where(query, [c], c.batch == ^batch), else: query
    Repo.all(query)
  end

  ## Federated identities

  @doc """
  Links an OIDC `issuer`/`subject` pair to `user`.

  Returns `{:error, :already_linked}` when that pair is already mapped.
  """
  @spec link_federated_identity(User.t(), String.t(), String.t()) ::
          {:ok, FederatedIdentity.t()} | {:error, :already_linked | Ecto.Changeset.t()}
  def link_federated_identity(%User{} = user, issuer, subject) do
    %FederatedIdentity{user_id: user.id}
    |> FederatedIdentity.changeset(%{issuer: issuer, subject: subject})
    |> Repo.insert()
    |> case do
      {:ok, identity} ->
        {:ok, identity}

      {:error, changeset} ->
        if unique_error?(changeset, :issuer),
          do: {:error, :already_linked},
          else: {:error, changeset}
    end
  end

  @doc "Resolves an OIDC issuer/subject pair to its global user, or `nil`."
  @spec get_user_by_federated_identity(String.t(), String.t()) :: User.t() | nil
  def get_user_by_federated_identity(issuer, subject) do
    Repo.one(
      from u in User,
        join: f in FederatedIdentity,
        on: f.user_id == u.id,
        where: f.issuer == ^issuer and f.subject == ^subject
    )
  end

  ## Internal helpers

  defp revoke_credential(struct, event_type, aggregate_type) do
    {:ok, revoked} =
      Repo.transaction(fn ->
        {:ok, revoked} =
          struct
          |> Ecto.Changeset.change(revoked_at: now())
          |> Repo.update()

        Audit.record!(:system, event_type,
          aggregate: {aggregate_type, revoked.id},
          payload: %{user_id: revoked.user_id}
        )

        revoked
      end)

    {:ok, revoked}
  end

  defp audit_session_revoked!(%Session{} = session) do
    Audit.record!(:system, "identity.session.revoked",
      aggregate: {"session", session.id},
      payload: %{user_id: session.user_id}
    )
  end

  defp hash_token(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
  end

  defp encode_token(token), do: Base.url_encode64(token, padding: false)

  defp decode_token(plain), do: Base.url_decode64(plain, padding: false)

  defp unique_error?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_msg, meta}} -> meta[:constraint] == :unique
      _other -> false
    end)
  end

  defp now, do: DateTime.utc_now()
end
