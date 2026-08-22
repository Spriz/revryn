defmodule BillingCore.Audit do
  @moduledoc """
  Append-only business audit trail (SPEC §13.3 `audit_log`, INV-028).

  `record!/2` must be called inside the same transaction as the domain change
  it evidences. The table rejects UPDATE/DELETE at the database level.
  """

  alias BillingCore.{Repo, Scope}
  alias BillingCore.Audit.Entry

  defmodule Entry do
    @moduledoc false
    use Ecto.Schema

    @type t :: %__MODULE__{}

    @schema_prefix "billing"
    @primary_key {:id, Ecto.UUID, autogenerate: true}
    schema "audit_log" do
      field :organization_id, Ecto.UUID
      field :team_id, Ecto.UUID
      field :actor_type, :string
      field :actor_id, :string
      field :event_type, :string
      field :aggregate_type, :string
      field :aggregate_id, Ecto.UUID
      field :correlation_id, Ecto.UUID
      field :causation_id, Ecto.UUID
      field :payload, :map
      field :occurred_at, :utc_datetime_usec
      field :created_at, :utc_datetime_usec
    end
  end

  @type actor :: Scope.t() | :system

  @doc """
  Appends an audit entry in the current transaction.

  Options: `:aggregate` (`{type, id}`), `:payload`, `:causation_id`,
  `:correlation_id` (defaults to the scope's), `:organization_id`, `:team_id`
  (default from scope when present).
  """
  @spec record!(actor(), String.t(), keyword()) :: Entry.t()
  def record!(actor, event_type, opts \\ []) do
    {aggregate_type, aggregate_id} =
      case Keyword.get(opts, :aggregate) do
        {type, id} -> {to_string(type), id}
        nil -> {nil, nil}
      end

    Repo.insert!(%Entry{
      organization_id: Keyword.get(opts, :organization_id, actor_org_id(actor)),
      team_id: Keyword.get(opts, :team_id, actor_team_id(actor)),
      actor_type: actor_type(actor),
      actor_id: actor_id(actor),
      event_type: event_type,
      aggregate_type: aggregate_type,
      aggregate_id: aggregate_id,
      correlation_id: Keyword.get(opts, :correlation_id, actor_correlation_id(actor)),
      causation_id: Keyword.get(opts, :causation_id),
      payload: Keyword.get(opts, :payload, %{}),
      occurred_at: DateTime.utc_now()
    })
  end

  defp actor_type(:system), do: "system"
  defp actor_type(%Scope{principal_type: :user}), do: "user"
  defp actor_type(%Scope{principal_type: :service}), do: "service"

  defp actor_id(:system), do: nil
  defp actor_id(%Scope{principal_type: :user, user: %{id: id}}), do: to_string(id)

  defp actor_id(%Scope{principal_type: :service, service_credential: %{id: id}}),
    do: to_string(id)

  defp actor_id(%Scope{}), do: nil

  defp actor_org_id(:system), do: nil
  defp actor_org_id(%Scope{organization: %{id: id}}), do: id
  defp actor_org_id(%Scope{}), do: nil

  defp actor_team_id(:system), do: nil
  defp actor_team_id(%Scope{team: %{id: id}}), do: id
  defp actor_team_id(%Scope{}), do: nil

  defp actor_correlation_id(%Scope{correlation_id: cid}), do: cid
  defp actor_correlation_id(_), do: nil
end
