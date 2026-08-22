defmodule BillingCore.ERP.EnvSecretProviderTest do
  @moduledoc """
  Default ERP secret resolution (SPEC §19.5): `secret_reference` names an
  environment variable holding `app_secret_token:agreement_grant_token`.
  The provider must fail loudly — not fall back — when the variable is
  missing or malformed, so a misconfigured deployment cannot silently talk
  to the wrong ERP agreement.
  """

  # async: false — mutates process-global OS environment variables.
  use ExUnit.Case, async: false

  alias BillingCore.ERP.EnvSecretProvider

  @env_var "BILLING_CORE_ENV_SECRET_PROVIDER_TEST"

  setup do
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  test "resolves a well-formed value into both credential tokens" do
    System.put_env(@env_var, "app-secret-token:agreement-grant-token")

    assert EnvSecretProvider.resolve!(@env_var) == %{
             app_secret_token: "app-secret-token",
             agreement_grant_token: "agreement-grant-token"
           }
  end

  test "splits on the first colon only, keeping colons inside the grant token" do
    System.put_env(@env_var, "app:grant:with:colons")

    assert EnvSecretProvider.resolve!(@env_var) == %{
             app_secret_token: "app",
             agreement_grant_token: "grant:with:colons"
           }
  end

  test "raises, naming the reference, when the variable is unset" do
    assert_raise RuntimeError,
                 "secret reference #{@env_var} is not resolvable in this environment",
                 fn -> EnvSecretProvider.resolve!(@env_var) end
  end

  test "raises on a value missing the token separator" do
    System.put_env(@env_var, "just-one-token-no-separator")

    assert_raise RuntimeError,
                 "secret reference #{@env_var} has an invalid format",
                 fn -> EnvSecretProvider.resolve!(@env_var) end
  end

  test "raises on an empty value rather than producing empty credentials" do
    System.put_env(@env_var, "")

    assert_raise RuntimeError, ~r/invalid format/, fn ->
      EnvSecretProvider.resolve!(@env_var)
    end
  end
end
