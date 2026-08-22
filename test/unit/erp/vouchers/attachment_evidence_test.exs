defmodule BillingCore.ERP.Vouchers.AttachmentEvidenceTest do
  use ExUnit.Case, async: true

  alias BillingCore.ERP.Vouchers.AttachmentEvidence

  @content "credit-close-report"

  defp evidence(overrides \\ []) do
    base = %AttachmentEvidence{
      filename: "credit-close.pdf",
      content_type: "application/pdf",
      content: @content,
      byte_size: byte_size(@content),
      sha256: :crypto.hash(:sha256, @content) |> Base.encode16(case: :lower)
    }

    struct!(base, overrides)
  end

  test "complete content evidence validates with default options" do
    assert AttachmentEvidence.validate(evidence()) == :ok
  end

  test "an uppercase sha256 still matches its content" do
    upper = :crypto.hash(:sha256, @content) |> Base.encode16(case: :upper)

    assert AttachmentEvidence.validate(evidence(sha256: upper)) == :ok
  end

  test "metadata-only evidence without hash or content is valid when content is not required" do
    metadata = evidence(content: nil, sha256: nil)

    assert AttachmentEvidence.validate(metadata) == :ok
  end

  test "missing filename and content type are both required" do
    assert {:error, errors} = AttachmentEvidence.validate(evidence(filename: nil))
    assert %{field: :filename, code: :required} in errors

    assert {:error, errors} = AttachmentEvidence.validate(evidence(content_type: ""))
    assert %{field: :content_type, code: :required} in errors
  end

  test "a hash that is not 64 hex characters is invalid" do
    assert {:error, errors} = AttachmentEvidence.validate(evidence(sha256: "abc123"))
    assert %{field: :sha256, code: :invalid_sha256} in errors
  end

  test "a missing hash is invalid when content is required" do
    missing_hash = evidence(content: nil, sha256: nil)

    assert {:error, errors} =
             AttachmentEvidence.validate(missing_hash, require_content: true)

    assert %{field: :sha256, code: :invalid_sha256} in errors
    assert %{field: :content, code: :required} in errors
  end

  test "byte_size must be a non-negative integer" do
    assert {:error, errors} = AttachmentEvidence.validate(evidence(byte_size: -1))
    assert %{field: :byte_size, code: :invalid_size} in errors

    assert {:error, errors} = AttachmentEvidence.validate(evidence(byte_size: nil))
    assert %{field: :byte_size, code: :invalid_size} in errors
  end

  test "non-binary content is invalid regardless of the content requirement" do
    assert {:error, errors} = AttachmentEvidence.validate(evidence(content: 42))
    assert %{field: :content, code: :invalid_content} in errors
  end

  test "content that disagrees with byte_size is rejected" do
    mismatch = evidence(byte_size: byte_size(@content) + 1)

    assert {:error, errors} = AttachmentEvidence.validate(mismatch)
    assert %{field: :byte_size, code: :content_size_mismatch} in errors
  end

  test "content that disagrees with the declared hash is rejected" do
    wrong_hash = :crypto.hash(:sha256, "other bytes") |> Base.encode16(case: :lower)

    assert {:error, errors} = AttachmentEvidence.validate(evidence(sha256: wrong_hash))
    assert %{field: :sha256, code: :content_hash_mismatch} in errors
  end
end
