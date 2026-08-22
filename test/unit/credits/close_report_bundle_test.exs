defmodule BillingCore.Credits.Close.ReportBundleTest do
  use ExUnit.Case, async: true

  alias BillingCore.Credits.Close.{Calculation, ReportBundle}

  test "creates a deterministic evidence bundle with a valid PDF header" do
    close = %{
      id: "00000000-0000-0000-0000-000000000010",
      team_id: "00000000-0000-0000-0000-000000000011",
      currency: "DKK",
      period_start: ~D[2026-07-01],
      period_end_exclusive: ~D[2026-08-01],
      transaction_cutoff: ~U[2026-08-01 00:00:00Z],
      policy_version_id: "00000000-0000-0000-0000-000000000012"
    }

    {:ok, snapshot} =
      Calculation.calculate(%{
        opening_minor: 0,
        closing_minor: 10,
        currency: "DKK",
        transactions: [
          %{
            id: "00000000-0000-0000-0000-000000000013",
            transaction_type: :grant,
            amount_minor: 10,
            currency: "DKK",
            accounting_effective_on: ~D[2026-07-01],
            occurred_at: ~U[2026-07-01 00:00:00Z],
            metadata: %{}
          }
        ]
      })

    assert bundle = ReportBundle.build!(close, snapshot)
    assert bundle == ReportBundle.build!(close, snapshot)
    assert String.starts_with?(bundle.pdf_summary, "%PDF-1.4")
    assert byte_size(bundle.report_sha256) == 64

    assert Enum.map(bundle.evidence, & &1.evidence_type) == [
             :canonical_json,
             :csv_detail,
             :pdf_summary,
             :manifest
           ]
  end
end
