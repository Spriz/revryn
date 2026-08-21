defmodule BillingCoreWeb.GraphQL.Middleware.SafeResolution do
  @moduledoc """
  Last-resort resolver exception boundary (SPEC §14.4).

  Unexpected resolver failures become a GraphQL error carrying only a stable
  code and the request correlation ID — never stack traces, SQL, secrets, or
  provider payloads. The full exception is logged server-side with the same
  correlation ID.
  """

  @behaviour Absinthe.Middleware

  require Logger

  alias Absinthe.Resolution

  @impl Absinthe.Middleware
  def call(%Resolution{} = resolution, resolver) do
    Absinthe.Resolution.call(resolution, resolver)
  rescue
    exception ->
      correlation_id = resolution.context[:correlation_id]

      Logger.error(
        "GraphQL resolver crashed (correlation_id=#{correlation_id}): " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      Resolution.put_result(
        resolution,
        {:error,
         %{
           message: "internal error",
           code: "INTERNAL_ERROR",
           correlation_id: correlation_id
         }}
      )
  end
end
