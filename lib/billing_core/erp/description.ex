defmodule BillingCore.ERP.Description do
  @moduledoc """
  Deterministic invoice-line description rendering (SPEC §17.6).

  Default format:

      <product display name> — <service start> to <inclusive service end>
      Usage: <quantity> <unit> @ <effective rate> <currency> | Ref: <line short id>

  Fixed charges omit the usage line. Discount and credit lines are prefixed
  `Discount:` / `Credit:`. Descriptions are NFC-normalized, control characters
  stripped, and truncated safely below the provider maximum while always
  retaining the short reference.
  """

  alias BillingCore.Domain.{Canonical, Period}
  alias BillingCore.ERP.Fingerprint

  @type opts :: [
          period: Period.t() | nil,
          quantity: Decimal.t() | nil,
          unit: String.t() | nil,
          rate: Decimal.t() | nil,
          currency: String.t() | nil,
          kind: :charge | :discount | :credit,
          line_ref: String.t(),
          max_length: pos_integer()
        ]

  @default_max_length 255

  @spec render(String.t(), opts()) :: String.t()
  def render(product_display_name, opts) do
    line_ref = Keyword.fetch!(opts, :line_ref)
    max_length = Keyword.get(opts, :max_length, @default_max_length)
    kind = Keyword.get(opts, :kind, :charge)
    period = Keyword.get(opts, :period)
    quantity = Keyword.get(opts, :quantity)

    prefix =
      case kind do
        :charge -> ""
        :discount -> "Discount: "
        :credit -> "Credit: "
      end

    headline =
      case period do
        nil ->
          "#{prefix}#{product_display_name}"

        %Period{} = p ->
          "#{prefix}#{product_display_name} — #{p.start_date} to #{Period.inclusive_end(p)}"
      end

    usage =
      if quantity do
        unit = Keyword.get(opts, :unit, "units")
        rate = Keyword.fetch!(opts, :rate)
        currency = Keyword.fetch!(opts, :currency)

        "Usage: #{Canonical.decimal_string(quantity)} #{unit} @ " <>
          "#{Canonical.decimal_string(rate)} #{currency} | Ref: #{line_ref}"
      else
        "Ref: #{line_ref}"
      end

    # Normalize each row separately so the two-line §17.6 format survives
    # normalization (normalize_text strips newline control characters).
    [headline, usage]
    |> Enum.map(&Fingerprint.normalize_text/1)
    |> Enum.join("\n")
    |> truncate_keeping_ref(line_ref, max_length)
  end

  # Truncation keeps the trailing `Ref: <id>` marker so a shortened
  # description remains traceable (SPEC §17.6).
  defp truncate_keeping_ref(text, line_ref, max_length) do
    if String.length(text) <= max_length do
      text
    else
      suffix = "… | Ref: #{line_ref}"
      keep = max(max_length - String.length(suffix), 0)
      String.slice(text, 0, keep) <> suffix
    end
  end
end
