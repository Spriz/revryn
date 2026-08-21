defmodule BillingCoreWeb.GraphQL.Context do
  @moduledoc """
  Builds the Absinthe context from the transport request (SPEC §14.2) and
  enforces transport-level document limits (SPEC §14.7).

  Authentication resolves a global principal from the `Authorization: Bearer`
  session/service token. Organization/team scope is resolved per operation
  from explicit arguments — possession of an ID never grants access.

  Oversized GraphQL documents are rejected before parsing with HTTP 413 and
  a stable error code; weighted query complexity is enforced separately by
  `Absinthe.Plug` (`analyze_complexity`, router).
  """

  @behaviour Plug

  import Plug.Conn

  alias BillingCore.Identity

  # SPEC §14.7: maximum document bytes (query text + encoded variables).
  @max_document_bytes 64 * 1024

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if document_size(conn) > @max_document_bytes do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        413,
        Jason.encode!(%{
          errors: [
            %{
              message:
                "GraphQL document exceeds the maximum size of #{@max_document_bytes} bytes",
              extensions: %{code: "DOCUMENT_TOO_LARGE"}
            }
          ]
        })
      )
      |> halt()
    else
      Absinthe.Plug.put_options(conn, context: build_context(conn))
    end
  end

  defp document_size(conn) do
    query_bytes =
      case conn.params["query"] do
        query when is_binary(query) -> byte_size(query)
        _other -> 0
      end

    variable_bytes =
      case conn.params["variables"] do
        variables when is_binary(variables) -> byte_size(variables)
        %{} = variables -> byte_size(Jason.encode!(variables))
        _other -> 0
      end

    query_bytes + variable_bytes
  end

  defp build_context(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         user when not is_nil(user) <- Identity.get_user_by_session_token(token) do
      %{current_user: user, correlation_id: correlation_id(conn)}
    else
      _ -> %{current_user: nil, correlation_id: correlation_id(conn)}
    end
  end

  # Correlation IDs propagate into audit/outbox rows (uuid columns), so only
  # a valid UUID header is honored; anything else gets a fresh ID.
  defp correlation_id(conn) do
    with [id | _] <- get_req_header(conn, "x-correlation-id"),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      uuid
    else
      _ -> Ecto.UUID.generate()
    end
  end
end
