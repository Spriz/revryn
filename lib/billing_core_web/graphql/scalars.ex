defmodule BillingCoreWeb.GraphQL.Scalars do
  @moduledoc """
  Custom scalars with strict coercion (SPEC §14.8).

  Monetary and quantity values serialize as strings or integers — never
  IEEE-754 JSON numbers where precision can be lost (INV-006).
  """

  use Absinthe.Schema.Notation

  alias Decimal, as: D

  scalar :date, name: "Date" do
    description("ISO 8601 calendar date, e.g. `2026-09-15`.")

    serialize(&Date.to_iso8601/1)

    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, date}
          _ -> :error
        end

      %Absinthe.Blueprint.Input.Null{} ->
        {:ok, nil}

      _ ->
        :error
    end)
  end

  scalar :datetime, name: "DateTime" do
    description("ISO 8601 UTC timestamp, e.g. `2026-08-21T15:00:00Z`.")

    serialize(fn %DateTime{} = dt ->
      dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
    end)

    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} ->
            # Normalize to microsecond precision so parsed values satisfy
            # `:utc_datetime_usec` columns regardless of input precision.
            {:ok, dt |> DateTime.shift_zone!("Etc/UTC") |> with_microsecond_precision()}

          _ ->
            :error
        end

      %Absinthe.Blueprint.Input.Null{} ->
        {:ok, nil}

      _ ->
        :error
    end)
  end

  @doc false
  def with_microsecond_precision(%DateTime{microsecond: {value, _precision}} = dt) do
    %{dt | microsecond: {value, 6}}
  end

  scalar :decimal, name: "Decimal" do
    description("""
    Arbitrary-precision decimal serialized as a string, e.g. `"12.5"`.
    Floats are rejected to protect precision.
    """)

    serialize(&BillingCore.Domain.Canonical.decimal_string/1)

    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        case D.parse(value) do
          {decimal, ""} -> {:ok, decimal}
          _ -> :error
        end

      %Absinthe.Blueprint.Input.Integer{value: value} ->
        {:ok, D.new(value)}

      %Absinthe.Blueprint.Input.Null{} ->
        {:ok, nil}

      _ ->
        :error
    end)
  end

  scalar :money_minor_units, name: "MoneyMinorUnits" do
    description("""
    Integer currency amount in minor units (e.g. øre/cents). Currency travels
    in a sibling field. JSON floats are rejected.
    """)

    serialize(fn
      %BillingCore.Domain.Money{minor_units: mu} -> mu
      minor when is_integer(minor) -> minor
    end)

    parse(fn
      %Absinthe.Blueprint.Input.Integer{value: value} -> {:ok, value}
      %Absinthe.Blueprint.Input.Null{} -> {:ok, nil}
      _ -> :error
    end)
  end

  scalar :json, name: "Json" do
    description("""
    A JSON object (string keys, JSON-safe values). Used only where a stable
    typed structure is not yet known (SPEC §14.8 discourages generic blobs;
    usage-event properties are schema-allowlisted downstream).
    """)

    serialize(& &1)

    parse(fn
      %Absinthe.Blueprint.Input.String{value: value} ->
        case Jason.decode(value) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> :error
        end

      %Absinthe.Blueprint.Input.Object{} = input ->
        {:ok, raw_json(input)}

      %Absinthe.Blueprint.Input.Null{} ->
        {:ok, nil}

      _ ->
        :error
    end)
  end

  defp raw_json(%Absinthe.Blueprint.Input.Object{fields: fields}) do
    Map.new(fields, fn field -> {field.name, raw_json(field.input_value.normalized)} end)
  end

  defp raw_json(%Absinthe.Blueprint.Input.List{items: items}) do
    Enum.map(items, fn item -> raw_json(item.normalized) end)
  end

  defp raw_json(%Absinthe.Blueprint.Input.Null{}), do: nil
  defp raw_json(%{value: value}), do: value
end
