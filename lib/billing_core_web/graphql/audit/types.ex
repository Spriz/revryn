defmodule BillingCoreWeb.GraphQL.Audit.Types do
  @moduledoc """
  Audit-package export types (BC-US-114, BC-TASK-072): canonical evidence
  files with per-file SHA-256 checksums for one invoice chain. Auditors
  hold read access; nothing here mutates.
  """

  use Absinthe.Schema.Notation

  @desc "One canonical evidence file with its exact bytes, base64-encoded."
  object :audit_export_file do
    field :name, non_null(:string)
    field :content_type, non_null(:string)
    field :sha256, non_null(:string)
    field :content_base64, non_null(:string)
  end

  @desc "An audit package for one invoice chain with its checksum manifest."
  object :audit_export do
    field :invoice_chain_id, non_null(:id)
    field :intent_count, non_null(:integer)
    field :generated_at, non_null(:string)

    @desc "Canonical JSON manifest listing per-file SHA-256 checksums."
    field :manifest_json, non_null(:string)
    field :files, non_null(list_of(non_null(:audit_export_file)))
  end
end
