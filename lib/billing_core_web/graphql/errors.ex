defmodule BillingCoreWeb.GraphQL.Errors do
  @moduledoc """
  Typed mutation problems and stable error codes (SPEC §14.4).

  Business mutations resolve to problem values tagged with `:__problem__`;
  union `resolve_type` dispatches on that tag and falls back to the
  mutation-specific success type. Expected business failures never surface
  as free-form GraphQL error strings, and unexpected failures never leak
  stack traces, SQL, or provider payloads — only a stable code plus the
  request correlation ID.
  """

  @type problem :: %{required(:__problem__) => atom(), optional(atom()) => term()}

  ## Problem constructors

  @spec validation(String.t(), String.t(), [map()], String.t() | nil) :: problem()
  def validation(code, message, fields \\ [], client_mutation_id \\ nil) do
    %{
      __problem__: :validation,
      code: code,
      message: message,
      fields: fields,
      client_mutation_id: client_mutation_id
    }
  end

  @spec mapping(String.t(), String.t(), [map()], String.t() | nil) :: problem()
  def mapping(code, message, fields \\ [], client_mutation_id \\ nil) do
    %{
      __problem__: :mapping,
      code: code,
      message: message,
      fields: fields,
      client_mutation_id: client_mutation_id
    }
  end

  @spec authorization(String.t() | nil) :: problem()
  def authorization(client_mutation_id \\ nil) do
    %{
      __problem__: :authorization,
      code: "UNAUTHORIZED",
      message: "not authorized for the requested scope or action",
      client_mutation_id: client_mutation_id
    }
  end

  @spec version_conflict(integer() | nil, integer() | nil, String.t() | nil) :: problem()
  def version_conflict(expected, actual, client_mutation_id \\ nil) do
    %{
      __problem__: :version_conflict,
      expected_version: expected,
      actual_version: actual,
      client_mutation_id: client_mutation_id
    }
  end

  @spec idempotency_conflict(String.t() | nil) :: problem()
  def idempotency_conflict(client_mutation_id \\ nil) do
    %{
      __problem__: :idempotency,
      code: "IDEMPOTENCY_KEY_REUSED",
      message: "idempotency key was reused with materially different input",
      client_mutation_id: client_mutation_id
    }
  end

  @doc "Field-level problems from a changeset (stable per-field codes)."
  @spec changeset_fields(Ecto.Changeset.t()) :: [map()]
  def changeset_fields(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message ->
        %{path: [to_string(field)], code: "INVALID", message: message}
      end)
    end)
  end

  @doc """
  Maps a domain `{:error, reason}` to the matching typed problem value.
  """
  @spec business_error(term(), String.t() | nil) :: problem()
  def business_error(reason, client_mutation_id \\ nil)

  def business_error(:unauthorized, cmid), do: authorization(cmid)

  def business_error(:idempotency_key_reused, cmid), do: idempotency_conflict(cmid)

  def business_error(%Ecto.Changeset{} = changeset, cmid) do
    validation("VALIDATION_FAILED", "input failed validation", changeset_fields(changeset), cmid)
  end

  def business_error(:conflict, cmid) do
    validation(
      "CONFLICT",
      "an external identifier was reused with a materially different payload",
      [],
      cmid
    )
  end

  def business_error({:blocked, blockers}, cmid) do
    fields =
      Enum.map(blockers, fn blocker ->
        %{path: [], code: blocker_code(blocker), message: blocker_message(blocker)}
      end)

    mapping("BLOCKED", "the command is blocked by unmet preconditions", fields, cmid)
  end

  def business_error({:illegal_state, _detail}, cmid) do
    validation("ILLEGAL_STATE", "the aggregate does not permit this transition", [], cmid)
  end

  def business_error({:invalid_pricing_definition, reasons}, cmid) do
    fields =
      Enum.map(List.wrap(reasons), fn reason ->
        %{path: ["pricingDefinition"], code: "INVALID", message: stringify(reason)}
      end)

    validation("INVALID_PRICING_DEFINITION", "pricing definition is invalid", fields, cmid)
  end

  def business_error({:invalid_pricing_definition, code, reasons}, cmid) do
    fields =
      Enum.map(List.wrap(reasons), fn reason ->
        %{path: ["components", to_string(code)], code: "INVALID", message: stringify(reason)}
      end)

    validation("INVALID_PRICING_DEFINITION", "pricing definition is invalid", fields, cmid)
  end

  def business_error(reason, cmid) when is_atom(reason) do
    code = reason |> Atom.to_string() |> String.upcase()
    validation(code, "the command was rejected: #{reason}", [], cmid)
  end

  def business_error(reason, cmid) when is_tuple(reason) do
    business_error(reason |> Tuple.to_list() |> List.first(), cmid)
  end

  def business_error(_reason, cmid) do
    validation("REJECTED", "the command was rejected", [], cmid)
  end

  @doc "Formats a preview blocker as a stable code string."
  @spec blocker_code(term()) :: String.t()
  def blocker_code({:metered_component, _code}), do: "METERED_COMPONENT"
  def blocker_code({:rating_failed, _code, _reason}), do: "RATING_FAILED"
  def blocker_code({:product_mapping_missing, _id}), do: "PRODUCT_MAPPING_MISSING"
  def blocker_code({:customer_mapping_missing, _id}), do: "CUSTOMER_MAPPING_MISSING"
  def blocker_code(other) when is_atom(other), do: other |> Atom.to_string() |> String.upcase()

  def blocker_code(other) when is_tuple(other),
    do: other |> elem(0) |> Atom.to_string() |> String.upcase()

  def blocker_code(_other), do: "BLOCKED"

  @doc "Human-readable blocker rendering (stable, no internals)."
  @spec blocker_message(term()) :: String.t()
  def blocker_message({:metered_component, code}), do: "metered component #{code} not previewable"
  def blocker_message({:rating_failed, code, _reason}), do: "rating failed for component #{code}"
  def blocker_message({:product_mapping_missing, id}), do: "product #{id} has no ERP mapping"
  def blocker_message({:customer_mapping_missing, id}), do: "customer #{id} has no ERP mapping"
  def blocker_message(other), do: stringify(other)

  @doc "Blocker rendered as `CODE` or `CODE:detail` for preview blocker lists."
  @spec blocker_string(term()) :: String.t()
  def blocker_string({:metered_component, code}), do: "METERED_COMPONENT:#{code}"
  def blocker_string({:rating_failed, code, _reason}), do: "RATING_FAILED:#{code}"
  def blocker_string({:product_mapping_missing, id}), do: "PRODUCT_MAPPING_MISSING:#{id}"
  def blocker_string({:customer_mapping_missing, id}), do: "CUSTOMER_MAPPING_MISSING:#{id}"
  def blocker_string(other), do: blocker_code(other)

  ## Union type resolution

  @doc """
  Resolves a mutation union member: problem values dispatch on their tag,
  everything else is the given success type.
  """
  @spec resolve_union(term(), atom()) :: atom()
  def resolve_union(%{__problem__: :validation}, _success), do: :validation_problem
  def resolve_union(%{__problem__: :mapping}, _success), do: :mapping_problem
  def resolve_union(%{__problem__: :authorization}, _success), do: :authorization_problem
  def resolve_union(%{__problem__: :version_conflict}, _success), do: :version_conflict
  def resolve_union(%{__problem__: :idempotency}, _success), do: :idempotency_conflict
  def resolve_union(_value, success), do: success

  ## Query-side errors (non-union fields)

  @doc "A stable-coded GraphQL error for query fields."
  @spec query_error(String.t(), String.t()) :: {:error, map()}
  def query_error(code, message) do
    {:error, %{message: message, code: code}}
  end

  @spec unauthenticated() :: {:error, map()}
  def unauthenticated do
    query_error("UNAUTHENTICATED", "authentication required")
  end

  @spec unauthorized() :: {:error, map()}
  def unauthorized do
    query_error("UNAUTHORIZED", "not authorized for the requested scope")
  end

  @spec not_found() :: {:error, map()}
  def not_found do
    query_error("NOT_FOUND", "resource not found in the requested scope")
  end

  defp stringify(term) when is_binary(term), do: term
  defp stringify(term) when is_atom(term), do: Atom.to_string(term)

  defp stringify({code, detail}) when is_atom(code),
    do: "#{code}:#{stringify(detail)}"

  defp stringify(term), do: inspect(term)
end
