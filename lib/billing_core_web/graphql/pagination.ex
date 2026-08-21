defmodule BillingCoreWeb.GraphQL.Pagination do
  @moduledoc """
  Keyset cursor connections (SPEC §14.6).

  Ordering is deterministic — ascending on a unique-ish sort column with the
  row ID as tie-break — and cursors are opaque base64 of `[sort_value, id]`.
  Page sizes are bounded server-side (default #{25}, maximum #{100});
  connection fields participate in complexity accounting via `complexity/2`.
  """

  import Ecto.Query

  alias BillingCore.Repo

  @default_page_size 25
  @max_page_size 100

  def default_page_size, do: @default_page_size
  def max_page_size, do: @max_page_size

  @doc """
  Runs `query` as a cursor connection ordered by `sort_field` (a string
  column) with `:id` tie-break. Args: `:first` (bounded) and `:after`.
  """
  @spec connection(Ecto.Query.t(), map(), atom()) ::
          {:ok, map()} | {:error, :invalid_page_size | :invalid_cursor}
  def connection(query, args, sort_field) do
    with {:ok, limit} <- page_size(args),
         {:ok, query} <- apply_cursor(query, args[:after], sort_field) do
      rows =
        query
        |> order_by([r], asc: field(r, ^sort_field), asc: r.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(rows, limit)

      edges =
        Enum.map(page, fn row ->
          %{cursor: encode_cursor(Map.fetch!(row, sort_field), row.id), node: row}
        end)

      {:ok,
       %{
         edges: edges,
         page_info: %{
           has_next_page: rest != [],
           end_cursor: edges |> List.last() |> then(&(&1 && &1.cursor))
         }
       }}
    end
  end

  defp page_size(args) do
    case args[:first] do
      nil -> {:ok, @default_page_size}
      first when is_integer(first) and first >= 1 and first <= @max_page_size -> {:ok, first}
      _out_of_bounds -> {:error, :invalid_page_size}
    end
  end

  defp apply_cursor(query, nil, _sort_field), do: {:ok, query}

  defp apply_cursor(query, cursor, sort_field) do
    case decode_cursor(cursor) do
      {:ok, {sort_value, id}} ->
        {:ok,
         where(
           query,
           [r],
           field(r, ^sort_field) > ^sort_value or
             (field(r, ^sort_field) == ^sort_value and r.id > ^id)
         )}

      :error ->
        {:error, :invalid_cursor}
    end
  end

  @doc "Opaque, versionable cursor for `{sort_value, id}`."
  @spec encode_cursor(String.t(), Ecto.UUID.t()) :: String.t()
  def encode_cursor(sort_value, id) do
    Base.url_encode64(Jason.encode!(["v1", sort_value, id]), padding: false)
  end

  @doc false
  @spec decode_cursor(String.t()) :: {:ok, {String.t(), Ecto.UUID.t()}} | :error
  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, ["v1", sort_value, id]} when is_binary(sort_value) <- Jason.decode(json),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, {sort_value, uuid}}
    else
      _ -> :error
    end
  end

  def decode_cursor(_cursor), do: :error

  @doc """
  Connection complexity: the subtree cost weighted by requested cardinality
  (SPEC §14.7). Each expected item contributes a tenth of its subtree cost,
  so wide pages of rich selections approach the request budget.
  """
  @spec complexity(map(), non_neg_integer()) :: pos_integer()
  def complexity(args, child_complexity) do
    limit = args |> Map.get(:first, @default_page_size) |> clamp()
    child = max(child_complexity, 1)
    1 + child + div(limit * child, 10)
  end

  defp clamp(first) when is_integer(first) and first >= 1, do: min(first, @max_page_size)
  defp clamp(_first), do: @default_page_size
end
