defmodule BillingCore.Pricing.SchemaTest do
  @moduledoc """
  Shared parsing/validation primitives for versioned pricing definitions
  (SPEC §9.6): header checking, decimal/integer field fetching (floats
  rejected per INV-006), and error accumulation.
  """
  use ExUnit.Case, async: true

  alias BillingCore.Pricing.Model.OneTime
  alias BillingCore.Pricing.Schema
  alias Decimal, as: D

  describe "check_header/2" do
    test "accepts the current version with the expected type" do
      assert :ok = Schema.check_header(%{"schema_version" => 1, "type" => "one_time"}, "one_time")
    end

    test "a mismatched type is reported as unexpected_type" do
      assert {:error, [{:unexpected_type, "fixed_recurring"}]} =
               Schema.check_header(
                 %{"schema_version" => 1, "type" => "fixed_recurring"},
                 "one_time"
               )
    end

    test "a missing type is reported as missing_type" do
      assert {:error, [:missing_type]} = Schema.check_header(%{"schema_version" => 1}, "one_time")
    end

    test "header failures accumulate instead of short-circuiting" do
      assert {:error, [{:unsupported_schema_version, 2}, :missing_type]} =
               Schema.check_header(%{"schema_version" => 2}, "one_time")

      assert {:error, [:missing_schema_version, :missing_type]} =
               Schema.check_header(%{}, "one_time")
    end

    test "a non-map definition is invalid_definition" do
      assert {:error, [:invalid_definition]} = Schema.check_header("one_time", "one_time")
      assert {:error, [:invalid_definition]} = Schema.check_header(nil, "one_time")
      assert {:error, [:invalid_definition]} = Schema.check_header([], "one_time")
    end

    test "per-module from_map surfaces header errors for direct callers" do
      # Model.from_map/1 dispatches on "type", so these branches are only
      # reachable through a concrete module's own from_map/1.
      assert {:error, [{:unexpected_type, "standard_metered"}]} =
               OneTime.from_map(%{
                 "schema_version" => 1,
                 "type" => "standard_metered",
                 "unit_price" => "1"
               })

      assert {:error, [:missing_type]} =
               OneTime.from_map(%{"schema_version" => 1, "unit_price" => "1"})

      assert {:error, [:invalid_definition]} = OneTime.from_map(:not_a_map)
    end
  end

  describe "fetch_decimal/2" do
    test "passes a Decimal value through, normalized for exact round-trips" do
      assert {:ok, value} = Schema.fetch_decimal(%{"rate" => D.new("1.500")}, "rate")
      assert value == D.new("1.5")
    end

    test "accepts an integer as an exact Decimal" do
      assert {:ok, value} = Schema.fetch_decimal(%{"rate" => 42}, "rate")
      assert value == D.new(42)
    end

    test "parses canonical decimal strings" do
      assert {:ok, value} = Schema.fetch_decimal(%{"rate" => "10.25"}, "rate")
      assert D.eq?(value, D.new("10.25"))
    end

    test "a missing key is missing_field" do
      assert {:error, {:missing_field, "rate"}} = Schema.fetch_decimal(%{}, "rate")
    end

    test "rejects floats (INV-006) and non-numeric values" do
      assert {:error, {:invalid_decimal, "rate"}} = Schema.fetch_decimal(%{"rate" => 1.5}, "rate")
      assert {:error, {:invalid_decimal, "rate"}} = Schema.fetch_decimal(%{"rate" => nil}, "rate")

      assert {:error, {:invalid_decimal, "rate"}} =
               Schema.fetch_decimal(%{"rate" => [1]}, "rate")
    end

    test "rejects unparsable and partially-parsable strings" do
      assert {:error, {:invalid_decimal, "rate"}} =
               Schema.fetch_decimal(%{"rate" => "abc"}, "rate")

      # A trailing remainder means the string is not a canonical decimal.
      assert {:error, {:invalid_decimal, "rate"}} =
               Schema.fetch_decimal(%{"rate" => "1.5abc"}, "rate")

      # Non-finite decimals carry a non-integer coefficient and are refused.
      assert {:error, {:invalid_decimal, "rate"}} =
               Schema.fetch_decimal(%{"rate" => "NaN"}, "rate")
    end
  end

  describe "fetch_non_neg_decimal/2" do
    test "zero is allowed, negative is not" do
      assert {:ok, value} = Schema.fetch_non_neg_decimal(%{"rate" => "0"}, "rate")
      assert D.eq?(value, D.new(0))

      assert {:error, {:negative, "rate"}} =
               Schema.fetch_non_neg_decimal(%{"rate" => "-0.01"}, "rate")
    end
  end

  describe "fetch_non_neg_int/3" do
    test "accepts non-negative integers and rejects everything else" do
      assert {:ok, 0} = Schema.fetch_non_neg_int(%{"n" => 0}, "n")
      assert {:ok, 7} = Schema.fetch_non_neg_int(%{"n" => 7}, "n")
      assert {:error, {:invalid_integer, "n"}} = Schema.fetch_non_neg_int(%{"n" => -1}, "n")
      assert {:error, {:invalid_integer, "n"}} = Schema.fetch_non_neg_int(%{"n" => "7"}, "n")
    end

    test "a missing key without a default is missing_field" do
      assert {:error, {:missing_field, "n"}} = Schema.fetch_non_neg_int(%{}, "n")
    end

    test "a missing key with a default returns the default" do
      assert {:ok, 0} = Schema.fetch_non_neg_int(%{}, "n", 0)
    end
  end

  describe "collect/1" do
    test "all-ok keeps values in order" do
      assert {:ok, [1, 2]} = Schema.collect([{:ok, 1}, {:ok, 2}])
    end

    test "any error drops values and flattens nested reason lists" do
      assert {:error, [:a, :b, :c]} =
               Schema.collect([{:ok, 1}, {:error, :a}, {:error, [:b, :c]}])
    end
  end
end
