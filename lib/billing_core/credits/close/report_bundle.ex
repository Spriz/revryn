defmodule BillingCore.Credits.Close.ReportBundle do
  @moduledoc "Deterministic canonical JSON, CSV, PDF, and SHA-256 report bundle."

  alias BillingCore.Domain.Canonical

  @type t :: %{
          canonical_json: binary(),
          csv_detail: binary(),
          pdf_summary: binary(),
          manifest: binary(),
          report_sha256: String.t(),
          evidence: [map()]
        }

  @spec build!(map(), map()) :: t()
  def build!(close, snapshot) do
    close_data = close_data(close, snapshot)
    canonical_json = Canonical.encode!(close_data)
    csv_detail = csv_detail(snapshot.transactions)
    pdf_summary = pdf_summary(close_data)

    manifest_data = %{
      close_id: Map.get(close, :id),
      files: %{
        "canonical.json" => sha256(canonical_json),
        "ledger.csv" => sha256(csv_detail),
        "summary.pdf" => sha256(pdf_summary)
      }
    }

    manifest = Canonical.encode!(manifest_data)
    report_sha256 = sha256(manifest)

    %{
      canonical_json: canonical_json,
      csv_detail: csv_detail,
      pdf_summary: pdf_summary,
      manifest: manifest,
      report_sha256: report_sha256,
      evidence: [
        evidence(:canonical_json, canonical_json, "application/json"),
        evidence(:csv_detail, csv_detail, "text/csv"),
        evidence(:pdf_summary, pdf_summary, "application/pdf"),
        evidence(:manifest, manifest, "application/json")
      ]
    }
  end

  defp close_data(close, snapshot) do
    %{
      close_id: Map.get(close, :id),
      team_id: Map.fetch!(close, :team_id),
      currency: Map.fetch!(close, :currency),
      period_start: Map.fetch!(close, :period_start),
      period_end_exclusive: Map.fetch!(close, :period_end_exclusive),
      transaction_cutoff: Map.fetch!(close, :transaction_cutoff),
      policy_version_id: Map.fetch!(close, :policy_version_id),
      opening_minor: snapshot.opening_minor,
      closing_minor: snapshot.closing_minor,
      net_change_minor: snapshot.net_change_minor,
      economic_liability_line_minor: snapshot.economic_liability_line_minor,
      ledger_transaction_count: snapshot.ledger_transaction_count,
      ledger_snapshot_hash: snapshot.ledger_snapshot_hash,
      # ADR-031: correction closes carry their kind, the close they correct,
      # and the approved reason inside the canonical report itself.
      close_kind: Map.get(close, :close_kind, :regular),
      reversal_of_close_id: Map.get(close, :reversal_of_close_id),
      correction_reason: Map.get(close, :correction_reason),
      movements: snapshot.movements,
      transactions: snapshot.transactions
    }
  end

  defp evidence(type, bytes, content_type) do
    %{
      evidence_type: type,
      bytes: bytes,
      sha256: sha256(bytes),
      content_type: content_type,
      metadata: %{}
    }
  end

  defp csv_detail(transactions) do
    header =
      "ledger_ordinal,transaction_id,accounting_effective_on,occurred_at,transaction_type,movement_type,amount_minor,liability_effect_minor,currency,credit_account_id,grant_id,reason_code\n"

    rows =
      transactions
      |> Enum.with_index(1)
      |> Enum.map(fn {transaction, ordinal} ->
        [
          ordinal,
          transaction.id,
          transaction.accounting_effective_on,
          transaction.occurred_at,
          transaction.transaction_type,
          transaction.movement_type,
          transaction.amount_minor,
          transaction.liability_effect_minor,
          transaction.currency,
          transaction.credit_account_id,
          transaction.grant_id,
          transaction.reason_code
        ]
        |> Enum.map_join(",", &csv_cell/1)
        |> Kernel.<>("\n")
      end)

    IO.iodata_to_binary([header, rows])
  end

  defp csv_cell(nil), do: ""
  defp csv_cell(%Date{} = value), do: csv_cell(Date.to_iso8601(value))
  defp csv_cell(%DateTime{} = value), do: csv_cell(DateTime.to_iso8601(value))
  defp csv_cell(value), do: "\"#{value |> to_string() |> String.replace("\"", "\"\"")}\""

  # A deliberately small valid PDF/A-like attachment with only the aggregate
  # accounting values; the canonical JSON/CSV retain complete audit detail.
  defp pdf_summary(data) do
    lines = [
      "Customer credit close #{Map.get(data, :close_id, "pending")}",
      "#{data.currency} #{Date.to_iso8601(data.period_start)} to #{Date.to_iso8601(data.period_end_exclusive)}",
      "Opening: #{data.opening_minor}",
      "Closing: #{data.closing_minor}",
      "Net change: #{data.net_change_minor}",
      "Debit-positive liability line: #{data.economic_liability_line_minor}",
      "Ledger hash: #{data.ledger_snapshot_hash}"
    ]

    content =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        "BT /F1 11 Tf 48 #{760 - index * 20} Td (#{pdf_text(line)}) Tj ET\n"
      end)
      |> IO.iodata_to_binary()

    objects = [
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n",
      "4 0 obj\n<< /Length #{byte_size(content)} >>\nstream\n#{content}endstream\nendobj\n",
      "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"
    ]

    header = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"

    {body, offsets, _position} =
      Enum.reduce(objects, {[], [], byte_size(header)}, fn object, {acc, positions, position} ->
        {[acc, object], [position | positions], position + byte_size(object)}
      end)

    body = IO.iodata_to_binary(body)
    xref_position = byte_size(header) + byte_size(body)

    xref = [
      "xref\n0 6\n0000000000 65535 f \n",
      Enum.reverse(offsets)
      |> Enum.map(&(String.pad_leading(Integer.to_string(&1), 10, "0") <> " 00000 n \n"))
    ]

    trailer = "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{xref_position}\n%%EOF\n"
    IO.iodata_to_binary([header, body, xref, trailer])
  end

  defp pdf_text(value) do
    value
    |> to_string()
    |> String.replace(~r/[^\x20-\x7E]/, "?")
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
