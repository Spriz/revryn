defmodule BillingCoreWeb.GraphQL.Audit.Resolvers do
  @moduledoc """
  Audit-package export resolver (BC-US-114) — a thin adapter over
  `BillingCore.AuditExport`, which enforces team scoping and role
  authorization (auditors included) itself.
  """

  alias BillingCore.AuditExport
  alias BillingCoreWeb.GraphQL.Errors

  def audit_export(_parent, %{invoice_intent_id: intent_id}, %{context: %{scope: scope}}) do
    case AuditExport.for_invoice_chain(scope, intent_id) do
      {:ok, %{files: files, manifest: manifest, manifest_json: manifest_json}} ->
        {:ok,
         %{
           invoice_chain_id: manifest.invoice_chain_id,
           intent_count: manifest.intent_count,
           generated_at: manifest.generated_at,
           manifest_json: manifest_json,
           files:
             Enum.map(files, fn file ->
               %{
                 name: file.name,
                 content_type: file.content_type,
                 sha256: file.sha256,
                 content_base64: Base.encode64(file.bytes)
               }
             end)
         }}

      {:error, :not_found} ->
        Errors.not_found()

      {:error, :unauthorized} ->
        Errors.unauthorized()
    end
  end
end
