defmodule BillingCore.ERPTest.EconomicClientStubAdapter do
  @moduledoc """
  Req module adapter for `BillingCore.ERP.Economic.Client` unit tests.

  Replaces the transport entirely (no HTTP), dispatching on the request path
  so tests can drive the client's `{:error, exception}` normalization branches
  that `Req.Test`'s plug transport cannot produce.
  """

  def run(%Req.Request{url: %URI{path: path}} = request) do
    case path do
      "/pre-decoded" ->
        {request, Req.Response.new(status: 200, body: %{"already" => "decoded"})}

      "/mint-transport-error" ->
        {request, %Mint.TransportError{reason: :nxdomain}}

      "/non-transport-error" ->
        {request, RuntimeError.exception("secret-token leaked?")}
    end
  end
end
