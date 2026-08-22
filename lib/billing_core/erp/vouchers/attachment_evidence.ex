defmodule BillingCore.ERP.Vouchers.AttachmentEvidence do
  @moduledoc """
  Immutable report-file evidence carried through the ERP attachment boundary.

  `content` is only used for upload. `sha256` and `byte_size` are the durable
  evidence read back and reconciled after the provider write.
  """

  @enforce_keys [:filename, :content_type, :sha256, :byte_size]
  defstruct [:filename, :content_type, :sha256, :byte_size, :content, :external_attachment_id]

  @type t :: %__MODULE__{
          filename: String.t(),
          content_type: String.t(),
          sha256: String.t() | nil,
          byte_size: non_neg_integer(),
          content: binary() | nil,
          external_attachment_id: String.t() | nil
        }

  @spec validate(t(), keyword()) :: :ok | {:error, [map()]}
  def validate(%__MODULE__{} = evidence, opts \\ []) do
    require_content? = Keyword.get(opts, :require_content, false)

    errors =
      []
      |> require(evidence.filename, :filename)
      |> require(evidence.content_type, :content_type)
      |> validate_hash(evidence.sha256, require_content?)
      |> validate_size(evidence.byte_size)
      |> validate_content(evidence, require_content?)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp require(errors, value, _field) when is_binary(value) and value != "", do: errors
  defp require(errors, _value, field), do: [%{field: field, code: :required} | errors]

  defp validate_hash(errors, hash, _require_content?)
       when is_binary(hash) and byte_size(hash) == 64,
       do: errors

  defp validate_hash(errors, nil, false), do: errors

  defp validate_hash(errors, _hash, _require_content?),
    do: [%{field: :sha256, code: :invalid_sha256} | errors]

  defp validate_size(errors, size) when is_integer(size) and size >= 0, do: errors
  defp validate_size(errors, _size), do: [%{field: :byte_size, code: :invalid_size} | errors]

  defp validate_content(errors, %__MODULE__{content: nil}, false), do: errors

  defp validate_content(errors, %__MODULE__{content: nil}, true),
    do: [%{field: :content, code: :required} | errors]

  defp validate_content(errors, %__MODULE__{} = evidence, _require_content?)
       when is_binary(evidence.content) do
    actual_hash = :crypto.hash(:sha256, evidence.content) |> Base.encode16(case: :lower)

    cond do
      byte_size(evidence.content) != evidence.byte_size ->
        [%{field: :byte_size, code: :content_size_mismatch} | errors]

      not is_binary(evidence.sha256) or actual_hash != String.downcase(evidence.sha256) ->
        [%{field: :sha256, code: :content_hash_mismatch} | errors]

      true ->
        errors
    end
  end

  defp validate_content(errors, _evidence, _require_content?),
    do: [%{field: :content, code: :invalid_content} | errors]
end
