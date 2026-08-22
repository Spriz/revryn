defmodule BillingCore.Pricing.ModelTest do
  @moduledoc """
  Pricing model data types and versioned definition maps (SPEC §9.6),
  including the from_map/to_map round-trip property (SPEC §23.3).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BillingCore.Domain.Canonical
  alias BillingCore.Pricing.{Model, Tier}

  alias BillingCore.Pricing.Model.{
    FixedRecurring,
    GraduatedTier,
    MinimumCommit,
    OneTime,
    Package,
    StandardMetered,
    VolumeTier
  }

  alias Decimal, as: D

  @tiers_map [
    %{"from" => "0", "to" => "100", "unit_rate" => "1.00", "flat_fee_minor" => 0},
    %{"from" => "100", "to" => "200", "unit_rate" => "0.90", "flat_fee_minor" => 0},
    %{"from" => "200", "unit_rate" => "0.80", "flat_fee_minor" => 500}
  ]

  defp header(type), do: %{"schema_version" => 1, "type" => type}

  describe "from_map/1 — happy paths" do
    test "fixed_recurring" do
      map = Map.put(header("fixed_recurring"), "unit_price", "100.00")
      assert {:ok, %FixedRecurring{unit_price: price}} = Model.from_map(map)
      assert D.eq?(price, D.new("100"))
    end

    test "one_time" do
      map = Map.put(header("one_time"), "unit_price", "500")
      assert {:ok, %OneTime{}} = Model.from_map(map)
    end

    test "standard_metered accepts zero rate (rates may be zero, not negative)" do
      map = Map.put(header("standard_metered"), "unit_rate", "0")
      assert {:ok, %StandardMetered{unit_rate: rate}} = Model.from_map(map)
      assert D.eq?(rate, D.new(0))
    end

    test "volume_tier and graduated_tier share the tier schema" do
      assert {:ok, %VolumeTier{tiers: [_, _, %Tier{to: nil, flat_fee_minor: 500}]}} =
               Model.from_map(Map.put(header("volume_tier"), "tiers", @tiers_map))

      assert {:ok, %GraduatedTier{tiers: [%Tier{from: from} | _]}} =
               Model.from_map(Map.put(header("graduated_tier"), "tiers", @tiers_map))

      assert D.eq?(from, D.new(0))
    end

    test "package" do
      map = Map.merge(header("package"), %{"package_size" => "10", "package_price" => "250.00"})
      assert {:ok, %Package{}} = Model.from_map(map)
    end

    test "minimum_commit wraps another model" do
      inner = Map.put(header("standard_metered"), "unit_rate", "5.00")

      map =
        Map.merge(header("minimum_commit"), %{"minimum_amount_minor" => 10_000, "inner" => inner})

      assert {:ok, %MinimumCommit{minimum_amount_minor: 10_000, inner: %StandardMetered{}}} =
               Model.from_map(map)
    end
  end

  describe "from_map/1 — validation" do
    test "missing or wrong schema version" do
      assert {:error, [:missing_schema_version]} =
               Model.from_map(%{"type" => "one_time", "unit_price" => "1"})

      assert {:error, [{:unsupported_schema_version, 2}]} =
               Model.from_map(%{"schema_version" => 2, "type" => "one_time", "unit_price" => "1"})
    end

    test "unknown or missing type" do
      assert {:error, [{:unknown_type, "nope"}]} =
               Model.from_map(%{"schema_version" => 1, "type" => "nope"})

      assert {:error, [:missing_type]} = Model.from_map(%{"schema_version" => 1})
      assert {:error, [:invalid_definition]} = Model.from_map("not a map")
    end

    test "floats are rejected (INV-006)" do
      map = Map.put(header("fixed_recurring"), "unit_price", 99.5)
      assert {:error, [{:invalid_decimal, "unit_price"}]} = Model.from_map(map)
    end

    test "negative rates are rejected; zero is allowed" do
      map = Map.put(header("fixed_recurring"), "unit_price", "-1")
      assert {:error, [{:negative, "unit_price"}]} = Model.from_map(map)

      assert {:ok, _} = Model.from_map(Map.put(header("fixed_recurring"), "unit_price", "0"))
    end

    test "tiers must start at zero" do
      tiers = [
        %{"from" => "1", "to" => "10", "unit_rate" => "1"},
        %{"from" => "10", "unit_rate" => "1"}
      ]

      assert {:error, errors} = Model.from_map(Map.put(header("volume_tier"), "tiers", tiers))
      assert :tiers_must_start_at_zero in errors
    end

    test "tier gaps and overlaps are rejected" do
      gap = [
        %{"from" => "0", "to" => "10", "unit_rate" => "1"},
        %{"from" => "11", "unit_rate" => "1"}
      ]

      overlap = [
        %{"from" => "0", "to" => "10", "unit_rate" => "1"},
        %{"from" => "9", "unit_rate" => "1"}
      ]

      assert {:error, [{:not_contiguous, 1}]} =
               Model.from_map(Map.put(header("volume_tier"), "tiers", gap))

      assert {:error, [{:not_contiguous, 1}]} =
               Model.from_map(Map.put(header("graduated_tier"), "tiers", overlap))
    end

    test "last tier must be unbounded and only the last may be unbounded" do
      bounded_last = [%{"from" => "0", "to" => "10", "unit_rate" => "1"}]

      assert {:error, [:last_tier_must_be_unbounded]} =
               Model.from_map(Map.put(header("volume_tier"), "tiers", bounded_last))

      unbounded_first = [
        %{"from" => "0", "unit_rate" => "1"},
        %{"from" => "10", "unit_rate" => "1"}
      ]

      assert {:error, errors} =
               Model.from_map(Map.put(header("volume_tier"), "tiers", unbounded_first))

      assert {:unbounded_tier_before_last, 0} in errors
    end

    test "empty tier list and empty tier ranges are rejected" do
      assert {:error, [:empty_tiers]} =
               Model.from_map(Map.put(header("volume_tier"), "tiers", []))

      empty_range = [
        %{"from" => "0", "to" => "0", "unit_rate" => "1"},
        %{"from" => "0", "unit_rate" => "1"}
      ]

      assert {:error, errors} =
               Model.from_map(Map.put(header("volume_tier"), "tiers", empty_range))

      assert {:empty_tier, 0} in errors
    end

    test "negative tier rate and flat fee are rejected with tier index" do
      tiers = [%{"from" => "0", "unit_rate" => "-1", "flat_fee_minor" => -5}]

      assert {:error, [{:tier, 0, reasons}]} =
               Model.from_map(Map.put(header("volume_tier"), "tiers", tiers))

      assert {:negative, "unit_rate"} in reasons
      assert {:invalid_integer, "flat_fee_minor"} in reasons
    end

    test "package_size must be strictly positive" do
      for size <- ["0", "-1"] do
        map = Map.merge(header("package"), %{"package_size" => size, "package_price" => "1"})
        assert {:error, [{:not_positive, "package_size"}]} = Model.from_map(map)
      end
    end

    test "minimum amount must be a non-negative integer" do
      inner = Map.put(header("one_time"), "unit_price", "1")

      map =
        Map.merge(header("minimum_commit"), %{"minimum_amount_minor" => -1, "inner" => inner})

      assert {:error, [{:invalid_integer, "minimum_amount_minor"}]} = Model.from_map(map)

      zero = Map.merge(header("minimum_commit"), %{"minimum_amount_minor" => 0, "inner" => inner})
      assert {:ok, %MinimumCommit{minimum_amount_minor: 0}} = Model.from_map(zero)
    end

    test "nested minimum commit is rejected" do
      inner_min =
        Map.merge(header("minimum_commit"), %{
          "minimum_amount_minor" => 1,
          "inner" => Map.put(header("one_time"), "unit_price", "1")
        })

      map =
        Map.merge(header("minimum_commit"), %{"minimum_amount_minor" => 1, "inner" => inner_min})

      assert {:error, [:nested_minimum_commit]} = Model.from_map(map)
    end

    test "multiple field errors are accumulated" do
      map = Map.merge(header("package"), %{"package_size" => "0", "package_price" => "-1"})
      assert {:error, errors} = Model.from_map(map)
      assert {:not_positive, "package_size"} in errors
      assert {:negative, "package_price"} in errors
    end
  end

  describe "to_map/1" do
    test "emits canonical decimal strings and the version header" do
      {:ok, model} = Model.from_map(Map.put(header("fixed_recurring"), "unit_price", "100.50"))

      assert Model.to_map(model) == %{
               "schema_version" => 1,
               "type" => "fixed_recurring",
               "unit_price" => "100.5"
             }
    end

    test "unbounded tier omits the to key" do
      {:ok, model} = Model.from_map(Map.put(header("volume_tier"), "tiers", @tiers_map))
      %{"tiers" => [_, _, last]} = Model.to_map(model)
      refute Map.has_key?(last, "to")
    end
  end

  describe "type/1 and per-module type/0 discriminators" do
    test "every struct maps to its wire discriminator" do
      {:ok, one_time} = Model.from_map(Map.put(header("one_time"), "unit_price", "1"))
      {:ok, metered} = Model.from_map(Map.put(header("standard_metered"), "unit_rate", "1"))
      {:ok, volume} = Model.from_map(Map.put(header("volume_tier"), "tiers", @tiers_map))
      {:ok, graduated} = Model.from_map(Map.put(header("graduated_tier"), "tiers", @tiers_map))
      {:ok, fixed} = Model.from_map(Map.put(header("fixed_recurring"), "unit_price", "1"))

      {:ok, package} =
        Model.from_map(
          Map.merge(header("package"), %{"package_size" => "10", "package_price" => "1"})
        )

      {:ok, minimum} =
        Model.from_map(
          Map.merge(header("minimum_commit"), %{
            "minimum_amount_minor" => 1,
            "inner" => Map.put(header("one_time"), "unit_price", "1")
          })
        )

      assert Model.type(one_time) == "one_time"
      assert Model.type(metered) == "standard_metered"
      assert Model.type(volume) == "volume_tier"
      assert Model.type(graduated) == "graduated_tier"
      assert Model.type(fixed) == "fixed_recurring"
      assert Model.type(package) == "package"
      assert Model.type(minimum) == "minimum_commit"

      # The struct discriminator always equals the map's "type" header, so
      # type/1 round-trips through to_map/1.
      for model <- [one_time, metered, volume, graduated, fixed, package, minimum] do
        assert Model.to_map(model)["type"] == Model.type(model)
      end
    end
  end

  describe "validate/1 on directly-constructed structs" do
    test "valid structs pass through every dispatch clause" do
      volume_tiers = [%Tier{from: D.new(0), to: nil, unit_rate: D.new(1), flat_fee_minor: 0}]

      minimum = %MinimumCommit{
        minimum_amount_minor: 100,
        inner: %StandardMetered{unit_rate: D.new("2")}
      }

      assert {:ok, _} = Model.validate(%OneTime{unit_price: D.new("1")})
      assert {:ok, _} = Model.validate(%StandardMetered{unit_rate: D.new("1")})
      assert {:ok, _} = Model.validate(%VolumeTier{tiers: volume_tiers})
      assert {:ok, ^minimum} = Model.validate(minimum)
    end

    test "a non-model term is rejected with unknown_model" do
      assert {:error, [{:unknown_model, %{not: :a_model}}]} = Model.validate(%{not: :a_model})
      assert {:error, [{:unknown_model, "one_time"}]} = Model.validate("one_time")
    end

    test "a struct whose money field is not a Decimal is rejected (INV-006)" do
      assert {:error, [{:invalid_decimal, "unit_price"}]} =
               Model.validate(%OneTime{unit_price: "1.00"})

      assert {:error, [{:invalid_decimal, "unit_rate"}]} =
               Model.validate(%StandardMetered{unit_rate: 1.0})
    end

    test "negative values are rejected on the struct too, not only in from_map" do
      assert {:error, [{:negative, "unit_price"}]} =
               Model.validate(%OneTime{unit_price: D.new("-1")})

      assert {:error, [{:negative, "unit_rate"}]} =
               Model.validate(%StandardMetered{unit_rate: D.new("-0.01")})
    end
  end

  describe "from_map/1 — missing required fields" do
    test "one_time and standard_metered without their rate field" do
      assert {:error, [{:missing_field, "unit_price"}]} = Model.from_map(header("one_time"))

      assert {:error, [{:missing_field, "unit_rate"}]} =
               Model.from_map(header("standard_metered"))
    end

    test "volume_tier without a tiers field" do
      assert {:error, [{:missing_field, "tiers"}]} = Model.from_map(header("volume_tier"))
    end

    test "minimum_commit without its minimum amount" do
      map =
        Map.put(header("minimum_commit"), "inner", Map.put(header("one_time"), "unit_price", "1"))

      assert {:error, errors} = Model.from_map(map)
      assert {:missing_field, "minimum_amount_minor"} in errors
    end
  end

  describe "Tier.contains?/2 — normative boundary rule" do
    test "exact boundary belongs to the tier whose from equals it" do
      lower = %Tier{from: D.new(0), to: D.new(100), unit_rate: D.new(1)}
      upper = %Tier{from: D.new(100), to: nil, unit_rate: D.new(1)}

      refute Tier.contains?(lower, D.new(100))
      assert Tier.contains?(upper, D.new(100))
      assert Tier.contains?(lower, D.new("99.999"))
      assert Tier.contains?(upper, D.new("100.001"))
    end
  end

  ## Generators

  defp decimal_string_gen(max_coef, max_scale) do
    gen all(
          coef <- integer(0..max_coef),
          scale <- integer(0..max_scale)
        ) do
      Canonical.decimal_string(D.new(1, coef, -scale))
    end
  end

  defp positive_decimal_string_gen(max_coef, max_scale) do
    gen all(
          coef <- integer(1..max_coef),
          scale <- integer(0..max_scale)
        ) do
      Canonical.decimal_string(D.new(1, coef, -scale))
    end
  end

  defp tiers_map_gen do
    gen all(
          increments <-
            list_of(positive_decimal_string_gen(10_000, 2), min_length: 0, max_length: 3),
          rates <- list_of(decimal_string_gen(100_000, 3), length: length(increments) + 1),
          fees <- list_of(integer(0..10_000), length: length(increments) + 1)
        ) do
      boundaries =
        increments
        |> Enum.map(&D.new/1)
        |> Enum.scan(D.new(0), fn increment, acc -> D.add(acc, increment) end)

      froms = [D.new(0) | boundaries]
      tos = Enum.map(boundaries, &Canonical.decimal_string/1) ++ [nil]

      [froms, tos, rates, fees]
      |> Enum.zip()
      |> Enum.map(fn {from, to, rate, fee} ->
        base = %{
          "from" => Canonical.decimal_string(from),
          "unit_rate" => rate,
          "flat_fee_minor" => fee
        }

        if to, do: Map.put(base, "to", to), else: base
      end)
    end
  end

  defp model_map_gen do
    simple = fn type, key ->
      gen all(value <- decimal_string_gen(10_000_000, 4)) do
        Map.put(%{"schema_version" => 1, "type" => type}, key, value)
      end
    end

    tiered = fn type ->
      gen all(tiers <- tiers_map_gen()) do
        %{"schema_version" => 1, "type" => type, "tiers" => tiers}
      end
    end

    package =
      gen all(
            size <- positive_decimal_string_gen(10_000, 2),
            price <- decimal_string_gen(1_000_000, 2)
          ) do
        %{
          "schema_version" => 1,
          "type" => "package",
          "package_size" => size,
          "package_price" => price
        }
      end

    non_minimum =
      one_of([
        simple.("fixed_recurring", "unit_price"),
        simple.("one_time", "unit_price"),
        simple.("standard_metered", "unit_rate"),
        tiered.("volume_tier"),
        tiered.("graduated_tier"),
        package
      ])

    minimum =
      gen all(
            inner <- non_minimum,
            amount <- integer(0..10_000_000)
          ) do
        %{
          "schema_version" => 1,
          "type" => "minimum_commit",
          "minimum_amount_minor" => amount,
          "inner" => inner
        }
      end

    one_of([non_minimum, minimum])
  end

  property "from_map/to_map round-trips for every model type (SPEC §23.3)" do
    check all(map <- model_map_gen()) do
      assert {:ok, model} = Model.from_map(map)
      round_tripped = Model.to_map(model)
      assert {:ok, model_again} = Model.from_map(round_tripped)
      assert model_again == model
      assert Model.to_map(model_again) == round_tripped
    end
  end
end
