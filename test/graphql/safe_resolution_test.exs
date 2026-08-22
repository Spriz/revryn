defmodule BillingCoreWeb.GraphQL.Middleware.SafeResolutionTest do
  @moduledoc """
  Resolver crash shielding (SPEC §14.4): unexpected exceptions become the
  stable `INTERNAL_ERROR` shape with the correlation ID — never the exception
  detail — while the full exception is logged server-side.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Absinthe.Resolution
  alias BillingCoreWeb.GraphQL.Middleware.SafeResolution

  @correlation_id "11111111-2222-4333-8444-555555555555"

  defp resolution(context \\ %{correlation_id: @correlation_id}) do
    %Resolution{context: context, arguments: %{}, source: %{}}
  end

  describe "normal resolution passes through" do
    test "a successful resolver result is untouched" do
      resolver = fn _args, _res -> {:ok, %{id: "row-1"}} end

      result = SafeResolution.call(resolution(), resolver)

      assert result.state == :resolved
      assert result.value == %{id: "row-1"}
      assert result.errors == []
    end

    test "an expected {:error, reason} result is not shielded" do
      resolver = fn _args, _res -> {:error, %{message: "nope", code: "NOT_FOUND"}} end

      result = SafeResolution.call(resolution(), resolver)

      assert result.state == :resolved
      assert result.errors == [%{message: "nope", code: "NOT_FOUND"}]
    end

    test "a 3-arity resolver is dispatched through Absinthe.Resolution.call" do
      resolver = fn _source, _args, _res -> {:ok, :three} end

      assert SafeResolution.call(resolution(), resolver).value == :three
    end

    test "an already-resolved resolution is returned unchanged" do
      resolved = %Resolution{state: :resolved, value: :left_alone, context: %{}}

      assert SafeResolution.call(resolved, fn _, _ -> raise "must not run" end) == resolved
    end
  end

  describe "crash shielding" do
    test "a raising resolver becomes the stable INTERNAL_ERROR shape" do
      resolver = fn _args, _res ->
        raise ArgumentError, "secret detail: SELECT * FROM users"
      end

      {result, log} = with_log(fn -> SafeResolution.call(resolution(), resolver) end)

      assert result.state == :resolved
      assert [error] = result.errors
      assert error.code == "INTERNAL_ERROR"
      assert error.message == "internal error"
      assert error.correlation_id == @correlation_id

      # The client-visible error never carries the exception internals.
      refute inspect(error) =~ "secret detail"
      refute inspect(error) =~ "ArgumentError"

      # The full exception is logged server-side under the same correlation ID.
      assert log =~ "GraphQL resolver crashed"
      assert log =~ @correlation_id
      assert log =~ "secret detail: SELECT * FROM users"
      assert log =~ "ArgumentError"
    end

    test "a crash without a correlation ID still yields the safe shape" do
      resolver = fn _args, _res -> raise "boom" end

      {result, _log} = with_log(fn -> SafeResolution.call(resolution(%{}), resolver) end)

      assert [%{code: "INTERNAL_ERROR", message: "internal error", correlation_id: nil}] =
               result.errors
    end
  end
end
