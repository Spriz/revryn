defmodule BillingCore.Identity.Totp do
  @moduledoc """
  TOTP secret handling (SPEC §19.2, BC-US-146): envelope encryption of
  seeds at rest and drift-tolerant code matching.

  Secrets are encrypted with AES-256-GCM under the 32-byte key configured
  as `config :billing_core, :credential_cipher_key` (base64-encoded).
  Development and test ship defaults; production must supply the key via
  the `CREDENTIAL_CIPHER_KEY` environment variable (config/runtime.exs) —
  the application refuses to handle TOTP secrets without it.

  The envelope layout is `<<version, iv::12-bytes, tag::16-bytes,
  ciphertext>>` with version `1`, leaving room for key rotation.

  Codes are matched with a ±#{1} period (30 s) drift window. Replay
  protection (rejecting a timestep twice) is enforced by the caller —
  `BillingCore.Identity.verify_totp/3` — via the factor's `last_timestep`.
  """

  @envelope_version 1
  @iv_bytes 12
  @tag_bytes 16
  @aad "billing_core.totp_secret.v1"
  @period 30
  @drift_periods 1
  @issuer "Billing Core"

  @doc "Generates a fresh random TOTP secret."
  @spec generate_secret() :: binary()
  def generate_secret, do: NimbleTOTP.secret()

  @doc "The otpauth:// provisioning URI for manual or QR entry."
  @spec otpauth_uri(binary(), String.t()) :: String.t()
  def otpauth_uri(secret, account_label) when is_binary(secret) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{account_label}", secret, issuer: @issuer)
  end

  @doc "Encrypts `secret` into an AES-256-GCM envelope."
  @spec encrypt_secret(binary()) :: binary()
  def encrypt_secret(secret) when is_binary(secret) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, cipher_key!(), iv, secret, @aad, true)

    <<@envelope_version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
      ciphertext::binary>>
  end

  @doc "Decrypts an envelope produced by `encrypt_secret/1`."
  @spec decrypt_secret(binary()) :: {:ok, binary()} | {:error, :decryption_failed}
  def decrypt_secret(
        <<@envelope_version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>
      ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           cipher_key!(),
           iv,
           ciphertext,
           @aad,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  end

  def decrypt_secret(other) when is_binary(other), do: {:error, :decryption_failed}

  @doc """
  Finds the timestep whose code matches, within the drift window.

  Checks the current period and ±#{@drift_periods} period around `at`
  (a Unix timestamp in seconds). Returns `{:ok, timestep}` or `:error`.
  """
  @spec matching_timestep(binary(), String.t(), integer()) :: {:ok, integer()} | :error
  def matching_timestep(secret, code, at \\ System.os_time(:second))
      when is_binary(secret) and is_binary(code) do
    offsets = Enum.to_list(-@drift_periods..@drift_periods)

    Enum.find_value(offsets, :error, fn offset ->
      time = at + offset * @period

      if valid_code?(secret, code, time), do: {:ok, div(time, @period)}
    end)
  end

  @doc "The TOTP period, in seconds."
  @spec period() :: pos_integer()
  def period, do: @period

  ## Internal helpers

  defp valid_code?(secret, code, time) do
    code = String.replace(code, ~r/\s/, "")
    String.length(code) == 6 and NimbleTOTP.valid?(secret, code, time: time, period: @period)
  end

  defp cipher_key! do
    encoded =
      case Application.fetch_env(:billing_core, :credential_cipher_key) do
        {:ok, value} when is_binary(value) ->
          value

        _missing ->
          raise """
          missing config :billing_core, :credential_cipher_key — a base64-encoded
          32-byte key. In production, provide it via the CREDENTIAL_CIPHER_KEY
          environment variable (config/runtime.exs).
          """
      end

    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 ->
        key

      _invalid ->
        raise ArgumentError,
              ":billing_core, :credential_cipher_key must be 32 bytes, base64-encoded"
    end
  end
end
