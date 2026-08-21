defmodule BillingCoreWeb.LiveHelpers do
  @moduledoc """
  Shared LiveView helpers: translating domain command errors into flash
  messages and parsing user input into domain types.

  Duplicate-submission safety (SPEC §23.6): domain contexts are idempotent
  and reject illegal lifecycle transitions; the UI's job is to render those
  rejections as flashes — never to crash the LiveView.
  """

  alias Ecto.Changeset

  @doc "Human-readable message for a domain command error."
  @spec error_message(term()) :: String.t()
  def error_message(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> case do
      "" -> "Invalid input."
      message -> message
    end
  end

  def error_message(:unauthorized), do: "You are not permitted to do that."
  def error_message(:not_found), do: "Not found."

  def error_message(:conflict),
    do: "A different request with the same identifier was already accepted."

  def error_message(:unresolved_intents),
    do: "The run still has unresolved invoice intents — resolve or supersede them first."

  def error_message(:invalid_state), do: "That action is not allowed in the current state."

  def error_message({:illegal_state, _error}),
    do: "That action is no longer available — the lifecycle has already advanced."

  def error_message({:blocked, blockers}),
    do: "Blocked: " <> Enum.map_join(blockers, ", ", &blocker_message/1)

  def error_message(:no_reconciled_draft),
    do: "No reconciled ERP draft exists for this invoice yet."

  def error_message(:not_approved), do: "The draft must be approved before booking."
  def error_message(:not_booked), do: "Corrections require a booked invoice."
  def error_message(:already_exists), do: "It already exists."
  def error_message(:already_member), do: "Already a member."

  def error_message({:connection_not_usable, status}),
    do: "The ERP connection is not usable (status: #{status}). Validate it in settings."

  def error_message(:missing_period_end_date),
    do: "End-of-period cancellation requires the billing period end date."

  def error_message(:invalid_quantity), do: "Enter a valid quantity greater than zero."
  def error_message(:invalid_mode), do: "Choose a cancellation mode."

  def error_message(:effective_date_in_past),
    do: "The effective date lies before the current version's start."

  def error_message(:effective_date_after_end),
    do: "The effective date lies after the subscription ends."

  def error_message(:not_draft), do: "Only draft plan versions can be published."
  def error_message(:no_components), do: "Add at least one price component before publishing."
  def error_message(:published_immutable), do: "Published plan versions are immutable."

  def error_message({:product_inactive, code}),
    do: "Product #{code} is inactive — reactivate it or remove the component."

  def error_message({:missing_product_version, code}),
    do: "Component #{code} pins a product version that does not exist."

  def error_message({:missing_service_period_source, code}),
    do: "Over-time component #{code} needs a service period source."

  def error_message({:invalid_pricing_definition, code, reasons}),
    do: "Component #{code} has an invalid pricing definition: #{inspect(reasons)}"

  def error_message({:unknown_line, line_key}), do: "Unknown invoice line #{line_key}."

  def error_message({:invalid_credit_amount, line_key}),
    do: "Enter a positive credit amount for line #{line_key}."

  def error_message({:credit_exceeds_original, line_key, %{} = detail}) do
    "Credit for line #{line_key} exceeds the remaining amount " <>
      "(original #{detail.original}, already credited #{detail.already_credited})."
  end

  def error_message(:not_an_erp_operation), do: "Only ERP operations can be retried here."

  def error_message(:no_effective_subscription_version),
    do: "No subscription version is effective on that date."

  def error_message(%{__struct__: _} = error), do: "The command failed: #{inspect(error)}"
  def error_message(other), do: "The command failed: #{inspect(other)}"

  defp blocker_message({:metered_component, code}),
    do: "metered component #{code} (usage not previewable)"

  defp blocker_message({:rating_failed, code, reason}),
    do: "rating failed for #{code}: #{inspect(reason)}"

  defp blocker_message({:product_mapping_missing, id}), do: "missing ERP product mapping (#{id})"

  defp blocker_message({:customer_mapping_missing, id}),
    do: "missing ERP customer mapping (#{id})"

  defp blocker_message(other), do: inspect(other)

  @doc "Parses an ISO 8601 date form field; `{:ok, date}` or `:error`."
  @spec parse_date(String.t() | nil) :: {:ok, Date.t()} | :error
  def parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  def parse_date(_value), do: :error

  @doc "Parses a decimal form field; `{:ok, decimal}` or `:error`."
  @spec parse_decimal(String.t() | nil) :: {:ok, Decimal.t()} | :error
  def parse_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> {:ok, decimal}
      _other -> :error
    end
  end

  def parse_decimal(_value), do: :error

  @doc """
  Parses a major-unit decimal amount into integer minor units for
  `currency`; `{:ok, minor}` or `:error` when not representable.
  """
  @spec parse_major_amount(String.t() | nil, String.t()) :: {:ok, integer()} | :error
  def parse_major_amount(value, currency) do
    with {:ok, decimal} <- parse_decimal(value) do
      exponent = BillingCore.Domain.Money.exponent(currency)
      scaled = Decimal.mult(decimal, Decimal.new(Integer.pow(10, exponent)))
      rounded = Decimal.round(scaled, 0)

      if Decimal.compare(scaled, rounded) == :eq do
        {:ok, Decimal.to_integer(rounded)}
      else
        :error
      end
    end
  end
end
