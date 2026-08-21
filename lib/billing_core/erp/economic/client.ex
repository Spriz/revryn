defmodule BillingCore.ERP.Economic.Client do
  @moduledoc """
  Single HTTP client boundary for the e-conomic REST API (SPEC §17.1, §17.2).

  Responsibilities:

    * builds one shared `Req` request with the provider auth headers taken from
      `connection_context.credentials` (`:app_secret_token` and
      `:agreement_grant_token`); credential values are never logged, inspected,
      or included in any returned error term;
    * explicit connect/receive timeouts, configurable via
      `connection_context.timeouts` (`:connect_ms` / `:receive_ms`);
    * transport-level retry is disabled (`retry: false`) — retry policy is an
      application-level concern (SPEC §17.7, §17.13), never the transport's;
    * non-GET writes carry the operation's `Idempotency-Key` header (§17.7);
    * response bodies are decoded with `Jason.decode(..., floats: :decimals)`
      so provider monetary numbers never touch binary floating point (INV-006);
    * a `:plug` key in the connection context routes requests through
      `Req.Test` for hermetic tests.

  Transport failures are returned as `{:error, {:transport, reason}}` where
  `reason` is a bare atom (e.g. `:timeout`, `:econnrefused`) — never a struct
  that could embed the request (and thus the credential headers).
  """

  @default_base_url "https://restapi.e-conomic.com"
  @default_connect_timeout_ms 5_000
  @default_receive_timeout_ms 15_000

  @type context :: BillingCore.ERP.Adapter.connection_context()

  @type response :: %{
          status: pos_integer(),
          headers: %{optional(String.t()) => [String.t()]},
          body: term()
        }

  @type result :: {:ok, response()} | {:error, {:transport, atom()}}

  @spec get(context(), String.t(), keyword()) :: result()
  def get(context, url, opts \\ []) do
    request(context, [method: :get, url: url] ++ opts)
  end

  @doc "POST write; `idempotency_key` is mandatory (SPEC §16.2, §17.7)."
  @spec post(context(), String.t(), map(), String.t(), keyword()) :: result()
  def post(context, url, json, idempotency_key, opts \\ [])
      when is_binary(idempotency_key) do
    request(
      context,
      [method: :post, url: url, json: json, idempotency_key: idempotency_key] ++ opts
    )
  end

  @doc "PUT write; `idempotency_key` is mandatory (SPEC §16.2, §17.7)."
  @spec put(context(), String.t(), map(), String.t(), keyword()) :: result()
  def put(context, url, json, idempotency_key, opts \\ [])
      when is_binary(idempotency_key) do
    request(
      context,
      [method: :put, url: url, json: json, idempotency_key: idempotency_key] ++ opts
    )
  end

  @spec request(context(), keyword()) :: result()
  def request(context, opts) do
    {idempotency_key, opts} = Keyword.pop(opts, :idempotency_key)

    req =
      context
      |> base_request()
      |> Req.merge(opts)
      |> put_idempotency_key(idempotency_key)

    case Req.request(req) do
      {:ok, %Req.Response{} = response} ->
        {:ok,
         %{
           status: response.status,
           headers: response.headers,
           body: decode_body(response.body)
         }}

      {:error, %Req.TransportError{reason: reason}} when is_atom(reason) ->
        {:error, {:transport, reason}}

      {:error, exception} ->
        # Reduce to a bare atom so no request struct (which carries the
        # credential headers) can leak into logs or error terms.
        {:error, {:transport, safe_reason(exception)}}
    end
  end

  defp base_request(context) do
    credentials = Map.get(context, :credentials) || %{}
    timeouts = Map.get(context, :timeouts) || %{}

    options = [
      base_url: Map.get(context, :base_url, @default_base_url),
      headers: [
        {"x-appsecrettoken", credential(credentials, :app_secret_token)},
        {"x-agreementgranttoken", credential(credentials, :agreement_grant_token)},
        {"content-type", "application/json"}
      ],
      retry: false,
      decode_body: false,
      connect_options: [timeout: Map.get(timeouts, :connect_ms, @default_connect_timeout_ms)],
      receive_timeout: Map.get(timeouts, :receive_ms, @default_receive_timeout_ms)
    ]

    options =
      case Map.get(context, :plug) do
        nil -> options
        plug -> Keyword.put(options, :plug, plug)
      end

    Req.new(options)
  end

  defp credential(credentials, key) do
    case Map.get(credentials, key) do
      value when is_binary(value) -> value
      _missing -> ""
    end
  end

  defp put_idempotency_key(req, nil), do: req

  defp put_idempotency_key(req, key) when is_binary(key) do
    Req.merge(req, headers: [{"idempotency-key", key}])
  end

  defp decode_body(body) when body in [nil, ""], do: nil

  defp decode_body(body) when is_binary(body) do
    # `floats: :decimals` keeps provider monetary numbers exact (INV-006).
    case Jason.decode(body, floats: :decimals) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_body(other), do: other

  defp safe_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp safe_reason(%struct{}), do: struct
  defp safe_reason(_other), do: :unexpected
end
