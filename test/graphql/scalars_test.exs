defmodule BillingCoreWeb.GraphQL.ScalarsTest do
  @moduledoc """
  Strict scalar coercion (SPEC §14.8, INV-006): monetary and quantity values
  never travel as IEEE-754 floats; malformed literals are rejected at parse.

  Each scalar's compiled parse/serialize functions are exercised directly via
  the schema's type definitions.
  """

  use ExUnit.Case, async: true

  alias Absinthe.Blueprint.Input
  alias Absinthe.Type.Scalar
  alias BillingCore.Domain.Money
  alias Decimal, as: D

  defp type(identifier) do
    Absinthe.Schema.lookup_type(BillingCoreWeb.GraphQL.Schema, identifier)
  end

  defp parse(identifier, input), do: Scalar.parse(type(identifier), input)
  defp serialize(identifier, value), do: Scalar.serialize(type(identifier), value)

  defp string(value), do: %Input.String{value: value}
  defp integer(value), do: %Input.Integer{value: value}
  defp float(value), do: %Input.Float{value: value}
  defp null, do: %Input.Null{}

  describe "Date" do
    test "serializes to ISO 8601" do
      assert serialize(:date, ~D[2026-09-15]) == "2026-09-15"
    end

    test "parses a valid ISO 8601 string" do
      assert parse(:date, string("2026-09-15")) == {:ok, ~D[2026-09-15]}
    end

    test "rejects invalid date strings" do
      assert parse(:date, string("2026-13-40")) == :error
      assert parse(:date, string("not-a-date")) == :error
    end

    test "parses explicit null" do
      assert parse(:date, null()) == {:ok, nil}
    end

    test "rejects non-string literals" do
      assert parse(:date, integer(20_260_915)) == :error
      assert parse(:date, float(2026.0915)) == :error
    end
  end

  describe "DateTime" do
    test "serializes UTC timestamps to ISO 8601" do
      assert serialize(:datetime, ~U[2026-08-21 15:00:00Z]) == "2026-08-21T15:00:00Z"
    end

    test "serializes zoned timestamps shifted to UTC" do
      dt = DateTime.new!(~D[2026-08-21], ~T[15:00:00], "Europe/Copenhagen")

      assert serialize(:datetime, dt) == "2026-08-21T13:00:00Z"
    end

    test "parses a UTC timestamp and normalizes to microsecond precision" do
      assert {:ok, %DateTime{} = dt} = parse(:datetime, string("2026-08-21T15:00:00Z"))
      assert dt.time_zone == "Etc/UTC"
      assert dt.microsecond == {0, 6}
      assert DateTime.compare(dt, ~U[2026-08-21 15:00:00.000000Z]) == :eq
    end

    test "parses an offset timestamp into normalized UTC" do
      assert {:ok, %DateTime{} = dt} = parse(:datetime, string("2026-08-21T15:00:00.5+02:00"))
      assert dt.time_zone == "Etc/UTC"
      assert dt.microsecond == {500_000, 6}
      assert DateTime.compare(dt, ~U[2026-08-21 13:00:00.500000Z]) == :eq
    end

    test "rejects date-only and malformed strings" do
      assert parse(:datetime, string("2026-08-21")) == :error
      assert parse(:datetime, string("yesterday")) == :error
      # Missing offset is not a valid ISO 8601 instant.
      assert parse(:datetime, string("2026-08-21T15:00:00")) == :error
    end

    test "parses explicit null and rejects non-string literals" do
      assert parse(:datetime, null()) == {:ok, nil}
      assert parse(:datetime, integer(1_755_788_400)) == :error
    end

    test "with_microsecond_precision/1 widens any parsed precision to 6" do
      {:ok, dt, _offset} = DateTime.from_iso8601("2026-08-21T15:00:00.25Z")

      assert BillingCoreWeb.GraphQL.Scalars.with_microsecond_precision(dt).microsecond ==
               {250_000, 6}
    end
  end

  describe "Decimal" do
    test "serializes canonically: no exponent, no trailing zeros, -0 collapses" do
      assert serialize(:decimal, D.new("12.50")) == "12.5"
      assert serialize(:decimal, D.new("1E+2")) == "100"
      assert serialize(:decimal, D.new("-0")) == "0"
    end

    test "parses a full decimal string" do
      assert {:ok, decimal} = parse(:decimal, string("12.5"))
      assert D.eq?(decimal, D.new("12.5"))
    end

    test "rejects trailing garbage and non-numeric strings" do
      assert parse(:decimal, string("12.5kg")) == :error
      assert parse(:decimal, string("abc")) == :error
    end

    test "parses integer literals exactly" do
      assert {:ok, decimal} = parse(:decimal, integer(42))
      assert D.eq?(decimal, D.new(42))
    end

    test "parses explicit null" do
      assert parse(:decimal, null()) == {:ok, nil}
    end

    test "rejects float literals to protect precision (INV-006)" do
      assert parse(:decimal, float(12.5)) == :error
    end
  end

  describe "MoneyMinorUnits" do
    test "serializes a Money struct to its integer minor units" do
      assert serialize(:money_minor_units, Money.new!("DKK", 12_500)) == 12_500
    end

    test "serializes a bare integer" do
      assert serialize(:money_minor_units, -990) == -990
    end

    test "parses integer literals" do
      assert parse(:money_minor_units, integer(12_500)) == {:ok, 12_500}
    end

    test "parses explicit null" do
      assert parse(:money_minor_units, null()) == {:ok, nil}
    end

    test "rejects float and string literals (no float money, INV-001)" do
      assert parse(:money_minor_units, float(125.0)) == :error
      assert parse(:money_minor_units, string("125")) == :error
    end
  end

  describe "Json" do
    test "serializes as passthrough" do
      assert serialize(:json, %{"a" => 1}) == %{"a" => 1}
    end

    test "parses a JSON object string" do
      assert parse(:json, string(~s({"plan":"pro","seats":3}))) ==
               {:ok, %{"plan" => "pro", "seats" => 3}}
    end

    test "rejects JSON strings that are not objects" do
      assert parse(:json, string(~s([1,2,3]))) == :error
      assert parse(:json, string(~s("scalar"))) == :error
      assert parse(:json, string("{not json")) == :error
    end

    test "parses an object literal with nested lists, nulls, and scalars" do
      object = %Input.Object{
        fields: [
          %Input.Field{
            name: "plan",
            input_value: %Input.Value{raw: nil, normalized: string("pro")}
          },
          %Input.Field{
            name: "seats",
            input_value: %Input.Value{raw: nil, normalized: integer(3)}
          },
          %Input.Field{name: "note", input_value: %Input.Value{raw: nil, normalized: null()}},
          %Input.Field{
            name: "tags",
            input_value: %Input.Value{
              raw: nil,
              normalized: %Input.List{
                items: [
                  %Input.Value{raw: nil, normalized: string("a")},
                  %Input.Value{raw: nil, normalized: null()}
                ]
              }
            }
          }
        ]
      }

      assert parse(:json, object) ==
               {:ok, %{"plan" => "pro", "seats" => 3, "note" => nil, "tags" => ["a", nil]}}
    end

    test "parses explicit null and rejects other literals" do
      assert parse(:json, null()) == {:ok, nil}
      assert parse(:json, integer(1)) == :error
      assert parse(:json, float(1.0)) == :error
    end
  end
end
