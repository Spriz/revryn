defmodule BillingCore.Reconciliation.ComparatorTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.{Money, Period}
  alias BillingCore.ERP.{CanonicalInvoice, Document, Fingerprint}
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.Reconciliation.Comparator
  alias BillingCore.Reconciliation.Comparator.{Difference, Result}

  defp expected_invoice(overrides \\ []) do
    period = Period.new!(~D[2026-09-15], ~D[2027-09-15])

    base = %CanonicalInvoice{
      external_reference: "abc:t1:intent-1:v1",
      document_type: :invoice,
      customer_external_id: "1001",
      recipient: %{legal_name: "Example ApS", country: "DK"},
      invoice_date: ~D[2026-09-01],
      currency: "DKK",
      payment_term_external_id: "14",
      layout_external_id: "21",
      delivery_mode: :none,
      lines: [
        %Line{
          order: 0,
          line_key: "sub:1:annual:2026-09-15",
          product_external_id: "SAAS-ANNUAL",
          description: "Annual platform subscription — 2026-09-15 to 2027-09-14",
          amount: Money.new!("DKK", 12_000_000),
          recognition: {:over_time, period}
        }
      ]
    }

    struct!(base, overrides)
  end

  defp matching_document(%CanonicalInvoice{} = expected, overrides \\ []) do
    base = %Document{
      state: :draft,
      external_draft_id: "draft-77",
      external_reference: expected.external_reference,
      customer_external_id: expected.customer_external_id,
      recipient_fingerprint: Fingerprint.recipient(expected.recipient),
      invoice_date: expected.invoice_date,
      currency: expected.currency,
      payment_term_external_id: expected.payment_term_external_id,
      layout_external_id: expected.layout_external_id,
      lines:
        Enum.map(expected.lines, fn line ->
          %{
            order: line.order,
            product_external_id: line.product_external_id,
            amount: line.amount,
            description_fingerprint: Fingerprint.description(line.description),
            recognition:
              case line.recognition do
                :point_in_time -> :point_in_time
                {:over_time, p} -> {:over_time, p.start_date, p.end_date_exclusive}
              end
          }
        end)
    }

    struct!(base, overrides)
  end

  test "an exactly matching draft reconciles with no differences" do
    expected = expected_invoice()
    actual = matching_document(expected)

    assert %Result{status: :match, differences: []} = Comparator.compare(expected, actual)
  end

  test "provider whitespace normalization still matches via fingerprints" do
    expected = expected_invoice()

    noisy_description = "Annual  platform subscription   — 2026-09-15 to 2027-09-14"

    actual =
      matching_document(expected)
      |> Map.update!(:lines, fn [line] ->
        [%{line | description_fingerprint: Fingerprint.description(noisy_description)}]
      end)

    assert %Result{status: :match} = Comparator.compare(expected, actual)
  end

  test "net line amount difference is fatal" do
    expected = expected_invoice()

    actual =
      matching_document(expected)
      |> Map.update!(:lines, fn [line] -> [%{line | amount: Money.new!("DKK", 11_999_999)}] end)

    assert %Result{status: :mismatch, differences: diffs} = Comparator.compare(expected, actual)
    assert Enum.any?(diffs, &(&1.field == :line_amount and &1.severity == :fatal))
    assert Enum.any?(diffs, &(&1.field == :net_amount and &1.severity == :fatal))
  end

  test "accrual date difference is fatal (BC-US-087)" do
    expected = expected_invoice()

    actual =
      matching_document(expected)
      |> Map.update!(:lines, fn [line] ->
        [%{line | recognition: {:over_time, ~D[2026-09-15], ~D[2027-09-14]}}]
      end)

    assert %Result{status: :mismatch, differences: diffs} = Comparator.compare(expected, actual)

    assert [%Difference{field: :recognition, severity: :fatal}] =
             Enum.filter(diffs, &(&1.field == :recognition))
  end

  test "missing recognition on an over-time line is fatal" do
    expected = expected_invoice()

    actual =
      matching_document(expected)
      |> Map.update!(:lines, fn [line] -> [%{line | recognition: :point_in_time}] end)

    assert %Result{status: :mismatch} = Comparator.compare(expected, actual)
  end

  test "missing and extra lines are fatal" do
    expected = expected_invoice()
    actual = matching_document(expected) |> Map.put(:lines, [])

    assert %Result{status: :mismatch, differences: diffs} = Comparator.compare(expected, actual)
    assert Enum.any?(diffs, &(&1.field == :missing_line))

    extra_line = %{
      order: 1,
      product_external_id: "OTHER",
      amount: Money.new!("DKK", 100),
      description_fingerprint: Fingerprint.description("added by human"),
      recognition: :point_in_time
    }

    actual2 = matching_document(expected) |> Map.update!(:lines, &(&1 ++ [extra_line]))
    assert %Result{status: :mismatch, differences: diffs2} = Comparator.compare(expected, actual2)
    assert Enum.any?(diffs2, &(&1.field == :extra_line))
  end

  test "changed recipient identity is fatal" do
    expected = expected_invoice()

    actual =
      matching_document(expected,
        recipient_fingerprint: Fingerprint.recipient(%{legal_name: "Other ApS", country: "DK"})
      )

    assert %Result{status: :mismatch, differences: diffs} = Comparator.compare(expected, actual)
    assert Enum.any?(diffs, &(&1.field == :recipient_fingerprint and &1.severity == :fatal))
  end

  test "provider line renumbering alone is a warning, not fatal" do
    expected = expected_invoice()

    actual =
      matching_document(expected)
      |> Map.update!(:lines, fn [line] -> [%{line | order: 5}] end)

    assert %Result{status: :match, differences: diffs} = Comparator.compare(expected, actual)
    assert [%Difference{field: :line_order, severity: :warning}] = diffs
  end
end
