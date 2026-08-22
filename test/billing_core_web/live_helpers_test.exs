defmodule BillingCoreWeb.LiveHelpersTest do
  @moduledoc """
  Flash-message translation and form-input parsing (SPEC §23.6): every
  domain rejection must render as a human-readable flash — never crash the
  LiveView — and user input parses into domain types (`Date`, `Decimal`,
  integer minor units) or fails cleanly.
  """

  use ExUnit.Case, async: true

  import BillingCoreWeb.LiveHelpers

  alias Ecto.Changeset

  describe "error_message/1 for changesets" do
    test "joins field errors and interpolates validation options" do
      changeset =
        {%{}, %{name: :string, batch: :integer}}
        |> Changeset.cast(%{"batch" => -1}, [:name, :batch])
        |> Changeset.validate_required([:name])
        |> Changeset.validate_number(:batch, greater_than: 0)

      message = error_message(changeset)

      assert message =~ "name can't be blank"
      # the %{number} option is interpolated, not left as a placeholder
      assert message =~ "batch must be greater than 0"
      refute message =~ "%{"
    end

    test "falls back to a generic message for a changeset without errors" do
      changeset = Changeset.cast({%{}, %{name: :string}}, %{}, [:name])

      assert error_message(changeset) == "Invalid input."
    end
  end

  describe "error_message/1 for domain rejection reasons" do
    # One entry per clause: {reason, fragment that must appear in the flash}.
    @reason_messages [
      {:unauthorized, "not permitted"},
      {:not_found, "Not found."},
      {:conflict, "same identifier was already accepted"},
      {:unresolved_intents, "unresolved invoice intents"},
      {:invalid_state, "not allowed in the current state"},
      {{:illegal_state, :frozen_to_booked}, "lifecycle has already advanced"},
      {:no_reconciled_draft, "No reconciled ERP draft"},
      {:not_approved, "approved before booking"},
      {:not_booked, "require a booked invoice"},
      {:already_exists, "already exists"},
      {:already_member, "Already a member"},
      {{:connection_not_usable, :degraded}, "not usable (status: degraded)"},
      {:missing_period_end_date, "requires the billing period end date"},
      {:invalid_quantity, "valid quantity greater than zero"},
      {:invalid_mode, "Choose a cancellation mode"},
      {:effective_date_in_past, "before the current version's start"},
      {:effective_date_after_end, "after the subscription ends"},
      {:not_draft, "Only draft plan versions"},
      {:no_components, "at least one price component"},
      {:published_immutable, "immutable"},
      {{:product_inactive, "SEAT"}, "Product SEAT is inactive"},
      {{:missing_product_version, "SEAT"}, "Component SEAT pins a product version"},
      {{:missing_service_period_source, "SUPPORT"}, "Over-time component SUPPORT"},
      {{:invalid_pricing_definition, "TIERED", [:missing_tier]},
       "Component TIERED has an invalid pricing definition: [:missing_tier]"},
      {{:unknown_line, "line-1"}, "Unknown invoice line line-1"},
      {{:invalid_credit_amount, "line-1"}, "positive credit amount for line line-1"},
      {:not_an_erp_operation, "Only ERP operations"},
      {:no_effective_subscription_version, "No subscription version is effective"}
    ]

    test "each reason maps to its dedicated human-readable message" do
      for {reason, fragment} <- @reason_messages do
        assert error_message(reason) =~ fragment,
               "expected error_message(#{inspect(reason)}) to mention #{inspect(fragment)}"
      end
    end

    test "credit_exceeds_original includes the remaining-amount detail" do
      message =
        error_message(
          {:credit_exceeds_original, "line-9",
           %{original: "100.00 DKK", already_credited: "40.00 DKK"}}
        )

      assert message =~ "line-9"
      assert message =~ "original 100.00 DKK"
      assert message =~ "already credited 40.00 DKK"
    end

    test "blocked errors enumerate every blocker with its dedicated wording" do
      message =
        error_message(
          {:blocked,
           [
             {:metered_component, "API_CALLS"},
             {:rating_failed, "SEAT", :missing_rate},
             {:product_mapping_missing, "prod-1"},
             {:customer_mapping_missing, "cust-1"},
             {:unexpected, :thing}
           ]}
        )

      assert message =~ "Blocked: "
      assert message =~ "metered component API_CALLS (usage not previewable)"
      assert message =~ "rating failed for SEAT: :missing_rate"
      assert message =~ "missing ERP product mapping (prod-1)"
      assert message =~ "missing ERP customer mapping (cust-1)"
      assert message =~ "{:unexpected, :thing}"
    end

    test "unknown structs and terms fall back to an inspected message" do
      assert error_message(%RuntimeError{message: "boom"}) =~ "The command failed: "
      assert error_message(%RuntimeError{message: "boom"}) =~ "boom"
      assert error_message({:surprise, 42}) == "The command failed: {:surprise, 42}"
    end
  end

  describe "parse_date/1" do
    test "parses ISO 8601 dates" do
      assert parse_date("2026-08-22") == {:ok, ~D[2026-08-22]}
    end

    test "rejects calendar-invalid, malformed, and non-binary input" do
      assert parse_date("2026-02-30") == :error
      assert parse_date("22/08/2026") == :error
      assert parse_date("") == :error
      assert parse_date(nil) == :error
    end
  end

  describe "parse_decimal/1" do
    test "parses decimals, trimming surrounding whitespace" do
      assert parse_decimal("10.5") == {:ok, Decimal.new("10.5")}
      assert parse_decimal("  -3  ") == {:ok, Decimal.new("-3")}
    end

    test "rejects trailing garbage, comma separators, and non-binary input" do
      assert parse_decimal("10.5abc") == :error
      assert parse_decimal("1,5") == :error
      assert parse_decimal("") == :error
      assert parse_decimal(nil) == :error
    end
  end

  describe "parse_major_amount/2" do
    test "scales by the currency exponent into integer minor units" do
      assert parse_major_amount("10.50", "DKK") == {:ok, 1050}
      assert parse_major_amount("-10.50", "DKK") == {:ok, -1050}
      assert parse_major_amount("100", "JPY") == {:ok, 100}
      assert parse_major_amount("1.234", "BHD") == {:ok, 1234}
    end

    test "rejects amounts not representable in the currency's minor units" do
      assert parse_major_amount("10.505", "DKK") == :error
      assert parse_major_amount("0.5", "JPY") == :error
    end

    test "propagates decimal parse failures" do
      assert parse_major_amount("ten", "DKK") == :error
      assert parse_major_amount(nil, "DKK") == :error
    end
  end
end
