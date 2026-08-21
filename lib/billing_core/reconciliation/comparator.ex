defmodule BillingCore.Reconciliation.Comparator do
  @moduledoc """
  Pure comparison of frozen invoice intent (as a canonical ERP invoice)
  against a normalized external ERP document (SPEC §17.14–17.15, BC-US-083,
  BC-US-087).

  Differences are classified:

    * `:fatal` — customer, frozen recipient fingerprint, currency, payment
      terms, layout, product, net line amount, missing line, extra line,
      recognition mode, or accrual dates differ. Fatal differences stop
      automation.
    * `:warning` — provider-normalized formatting differs while normalized
      fingerprints remain equivalent (e.g. description text differs but
      fingerprint matches after normalization, provider line numbering).
    * `:informational` — provider-calculated VAT, invoice number, PDF link,
      or payment state changed.
  """

  alias BillingCore.Domain.Period
  alias BillingCore.ERP.{CanonicalInvoice, Document, Fingerprint}

  defmodule Difference do
    @moduledoc false
    @enforce_keys [:severity, :field]
    defstruct [:severity, :field, :line_key, :line_order, :expected, :actual]

    @type t :: %__MODULE__{
            severity: :fatal | :warning | :informational,
            field: atom(),
            line_key: String.t() | nil,
            line_order: non_neg_integer() | nil,
            expected: term(),
            actual: term()
          }
  end

  defmodule Result do
    @moduledoc false
    @enforce_keys [:status, :differences]
    defstruct [:status, :differences]

    @type t :: %__MODULE__{
            status: :match | :mismatch,
            differences: [Difference.t()]
          }
  end

  @doc """
  Compares expected canonical invoice to the normalized external document.
  `status` is `:mismatch` when any fatal difference exists; warnings and
  informational differences alone still yield `:match` (visibility is the
  caller's concern per team policy).
  """
  @spec compare(CanonicalInvoice.t(), Document.t()) :: Result.t()
  def compare(%CanonicalInvoice{} = expected, %Document{} = actual) do
    differences =
      header_differences(expected, actual) ++ line_differences(expected, actual)

    status =
      if Enum.any?(differences, &(&1.severity == :fatal)), do: :mismatch, else: :match

    %Result{status: status, differences: differences}
  end

  defp header_differences(expected, actual) do
    expected_recipient_fp = Fingerprint.recipient(expected.recipient)

    [
      fatal_if_differs(
        :external_reference,
        expected.external_reference,
        actual.external_reference
      ),
      fatal_if_differs(
        :customer_external_id,
        expected.customer_external_id,
        actual.customer_external_id
      ),
      fatal_if_differs(:currency, expected.currency, actual.currency),
      fatal_if_differs(:invoice_date, expected.invoice_date, actual.invoice_date),
      fatal_if_differs(
        :payment_term_external_id,
        expected.payment_term_external_id,
        actual.payment_term_external_id
      ),
      fatal_if_differs(
        :layout_external_id,
        expected.layout_external_id,
        actual.layout_external_id
      ),
      fatal_if_differs(
        :recipient_fingerprint,
        expected_recipient_fp,
        actual.recipient_fingerprint
      ),
      net_amount_difference(expected, actual)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp net_amount_difference(expected, actual) do
    expected_net = CanonicalInvoice.net_amount(expected)
    actual_net = Document.net_amount(actual)

    if expected_net.minor_units != actual_net.minor_units or
         expected_net.currency != actual_net.currency do
      %Difference{
        severity: :fatal,
        field: :net_amount,
        expected: {expected_net.currency, expected_net.minor_units},
        actual: {actual_net.currency, actual_net.minor_units}
      }
    end
  end

  defp line_differences(expected, actual) do
    expected_lines = Enum.sort_by(expected.lines, & &1.order)
    actual_lines = Enum.sort_by(actual.lines, & &1.order)

    count_diffs =
      cond do
        length(expected_lines) > length(actual_lines) ->
          expected_lines
          |> Enum.drop(length(actual_lines))
          |> Enum.map(fn line ->
            %Difference{
              severity: :fatal,
              field: :missing_line,
              line_key: line.line_key,
              line_order: line.order,
              expected: line.product_external_id,
              actual: nil
            }
          end)

        length(actual_lines) > length(expected_lines) ->
          actual_lines
          |> Enum.drop(length(expected_lines))
          |> Enum.map(fn line ->
            %Difference{
              severity: :fatal,
              field: :extra_line,
              line_order: line.order,
              expected: nil,
              actual: line.product_external_id
            }
          end)

        true ->
          []
      end

    pair_diffs =
      expected_lines
      |> Enum.zip(actual_lines)
      |> Enum.flat_map(fn {exp, act} -> compare_line(exp, act) end)

    pair_diffs ++ count_diffs
  end

  defp compare_line(exp, act) do
    [
      line_fatal_if_differs(
        exp,
        :product_external_id,
        exp.product_external_id,
        act.product_external_id
      ),
      line_amount_difference(exp, act),
      description_difference(exp, act),
      recognition_difference(exp, act),
      line_order_warning(exp, act)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp line_amount_difference(exp, act) do
    if exp.amount.minor_units != act.amount.minor_units or
         exp.amount.currency != act.amount.currency do
      %Difference{
        severity: :fatal,
        field: :line_amount,
        line_key: exp.line_key,
        line_order: exp.order,
        expected: {exp.amount.currency, exp.amount.minor_units},
        actual: {act.amount.currency, act.amount.minor_units}
      }
    end
  end

  defp description_difference(exp, act) do
    expected_fp = Fingerprint.description(exp.description)

    if expected_fp != act.description_fingerprint do
      %Difference{
        severity: :fatal,
        field: :description_fingerprint,
        line_key: exp.line_key,
        line_order: exp.order,
        expected: expected_fp,
        actual: act.description_fingerprint
      }
    end
  end

  defp recognition_difference(exp, act) do
    expected_recognition =
      case exp.recognition do
        :point_in_time -> :point_in_time
        {:over_time, %Period{} = p} -> {:over_time, p.start_date, p.end_date_exclusive}
      end

    if expected_recognition != act.recognition do
      %Difference{
        severity: :fatal,
        field: :recognition,
        line_key: exp.line_key,
        line_order: exp.order,
        expected: expected_recognition,
        actual: act.recognition
      }
    end
  end

  defp line_order_warning(exp, act) do
    if exp.order != act.order do
      %Difference{
        severity: :warning,
        field: :line_order,
        line_key: exp.line_key,
        line_order: exp.order,
        expected: exp.order,
        actual: act.order
      }
    end
  end

  defp fatal_if_differs(field, expected, actual) do
    if expected != actual do
      %Difference{severity: :fatal, field: field, expected: expected, actual: actual}
    end
  end

  defp line_fatal_if_differs(exp, field, expected, actual) do
    if expected != actual do
      %Difference{
        severity: :fatal,
        field: field,
        line_key: exp.line_key,
        line_order: exp.order,
        expected: expected,
        actual: actual
      }
    end
  end
end
