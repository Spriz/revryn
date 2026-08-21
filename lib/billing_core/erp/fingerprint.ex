defmodule BillingCore.ERP.Fingerprint do
  @moduledoc """
  Deterministic fingerprints for reconciliation comparison (SPEC §17.14).

  Providers normalize whitespace and empty address fields; fingerprints are
  computed over a normalized shape on both the expected and actual side so
  such provider normalization compares as equivalent (§17.15 warnings, not
  fatal differences).
  """

  alias BillingCore.Domain.Canonical

  @doc """
  Fingerprint of a recipient identity/address snapshot. Keys with empty/nil
  values are dropped; strings are NFC-normalized with collapsed whitespace.
  """
  @spec recipient(map()) :: String.t()
  def recipient(recipient) when is_map(recipient) do
    recipient
    |> Map.take([
      :legal_name,
      :address,
      :zip,
      :city,
      :country,
      :email,
      :vat_number,
      :vat_zone_external_id,
      "legal_name",
      "address",
      "zip",
      "city",
      "country",
      "email",
      "vat_number",
      "vat_zone_external_id"
    ])
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_text(v)} end)
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
    |> Canonical.hash()
  end

  @doc """
  Fingerprint of a line description: Unicode NFC, control characters stripped,
  whitespace collapsed, trimmed. Truncation-tolerant comparison is the
  caller's concern; the fingerprint is over the full normalized text.
  """
  @spec description(String.t() | nil) :: String.t()
  def description(text) do
    text
    |> normalize_text()
    |> Kernel.||("")
    |> Canonical.hash()
  end

  @doc """
  Normalizes text for provider-tolerant comparison: NFC, strips control
  characters, collapses runs of whitespace to single spaces, trims. Returns
  `nil` for `nil`.
  """
  @spec normalize_text(String.t() | nil) :: String.t() | nil
  def normalize_text(nil), do: nil

  def normalize_text(text) when is_binary(text) do
    text
    |> String.normalize(:nfc)
    |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def normalize_text(other), do: other |> to_string() |> normalize_text()
end
