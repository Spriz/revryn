defmodule BillingCore.RuntimeSecretsTest do
  # Not async: mutates process-global environment variables.
  use ExUnit.Case, async: false

  alias BillingCore.Release

  @var "REVRYN_TEST_SECRET"

  setup do
    on_exit(fn ->
      System.delete_env(@var)
      System.delete_env(@var <> "_FILE")
    end)

    :ok
  end

  test "reads the plain environment variable" do
    System.put_env(@var, "plain-value")
    assert Release.read_secret(@var) == "plain-value"
  end

  test "falls back to the _FILE indirection and trims the trailing newline" do
    path = Path.join(System.tmp_dir!(), "revryn-secret-#{System.unique_integer([:positive])}")
    File.write!(path, "file-value\n")
    on_exit(fn -> File.rm(path) end)

    System.put_env(@var <> "_FILE", path)
    assert Release.read_secret(@var) == "file-value"
  end

  test "a set variable wins over the _FILE indirection" do
    path = Path.join(System.tmp_dir!(), "revryn-secret-#{System.unique_integer([:positive])}")
    File.write!(path, "file-value")
    on_exit(fn -> File.rm(path) end)

    System.put_env(@var, "env-wins")
    System.put_env(@var <> "_FILE", path)
    assert Release.read_secret(@var) == "env-wins"
  end

  test "returns nil when neither form is set" do
    assert Release.read_secret(@var) == nil
  end

  test "raises on an unreadable _FILE path rather than booting half-configured" do
    System.put_env(@var <> "_FILE", "/nonexistent/revryn-secret")
    assert_raise File.Error, fn -> Release.read_secret(@var) end
  end
end
