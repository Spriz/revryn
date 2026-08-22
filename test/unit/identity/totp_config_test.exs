defmodule BillingCore.Identity.TotpConfigTest do
  @moduledoc """
  Cipher-key configuration guardrails (SPEC §19.2): the application refuses
  to handle TOTP secrets without a valid base64-encoded 32-byte
  `:credential_cipher_key`. Sync (async: false) because the key lives in the
  global application environment.
  """

  use ExUnit.Case, async: false

  alias BillingCore.Identity.Totp

  setup do
    previous = Application.fetch_env!(:billing_core, :credential_cipher_key)
    on_exit(fn -> Application.put_env(:billing_core, :credential_cipher_key, previous) end)
    %{previous: previous}
  end

  test "a missing cipher key raises with remediation guidance" do
    Application.delete_env(:billing_core, :credential_cipher_key)

    assert_raise RuntimeError, ~r/missing config :billing_core, :credential_cipher_key/, fn ->
      Totp.encrypt_secret("seed")
    end
  end

  test "a non-base64 cipher key raises ArgumentError" do
    Application.put_env(:billing_core, :credential_cipher_key, "%%% not base64 %%%")

    assert_raise ArgumentError, ~r/32 bytes, base64-encoded/, fn ->
      Totp.encrypt_secret("seed")
    end
  end

  test "a wrong-length cipher key raises ArgumentError" do
    Application.put_env(
      :billing_core,
      :credential_cipher_key,
      Base.encode64(:crypto.strong_rand_bytes(16))
    )

    assert_raise ArgumentError, ~r/32 bytes, base64-encoded/, fn ->
      Totp.encrypt_secret("seed")
    end
  end

  test "decryption also refuses to run without the key", %{previous: previous} do
    envelope = Totp.encrypt_secret("seed")
    Application.delete_env(:billing_core, :credential_cipher_key)

    assert_raise RuntimeError, ~r/credential_cipher_key/, fn ->
      Totp.decrypt_secret(envelope)
    end

    Application.put_env(:billing_core, :credential_cipher_key, previous)
    assert {:ok, "seed"} = Totp.decrypt_secret(envelope)
  end
end
