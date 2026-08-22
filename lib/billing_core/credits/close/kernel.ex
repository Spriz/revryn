defmodule BillingCore.Credits.Close do
  @moduledoc """
  Narrow close-domain kernel for the durable close orchestration context.

  It owns pure calculation/report generation and scoped persistence of frozen
  report bytes. Locking, transaction membership insertion, outbox events, and
  ERP effects deliberately remain with the enclosing command transaction.
  """

  import Ecto.Query

  alias BillingCore.{Repo, Scope}

  alias BillingCore.Credits.Close.{
    Authorization,
    Calculation,
    Close,
    Evidence,
    Lifecycle,
    PolicyVersion,
    ReportBundle
  }

  @spec create_policy(Scope.t(), map()) ::
          {:ok, PolicyVersion.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_policy(%Scope{} = scope, attrs) when is_map(attrs) do
    if Scope.team_scoped?(scope) do
      policy = %PolicyVersion{team_id: Scope.team_id!(scope)}

      with :ok <- Authorization.authorize(scope, policy, :write) do
        policy
        |> policy_changeset(attrs)
        |> Repo.insert()
      end
    else
      {:error, :unauthorized}
    end
  end

  @spec calculate(map()) :: {:ok, Calculation.snapshot()} | {:error, term()}
  defdelegate calculate(input), to: Calculation

  @spec build_report(map(), Calculation.snapshot()) :: ReportBundle.t()
  defdelegate build_report(close, snapshot), to: ReportBundle, as: :build!

  @spec persist_report(Scope.t(), Close.t(), ReportBundle.t()) ::
          {:ok, non_neg_integer()} | {:error, :unauthorized}
  def persist_report(%Scope{} = scope, %Close{} = close, %{evidence: evidence}) do
    with :ok <- Authorization.authorize(scope, close, :write) do
      rows =
        Enum.map(evidence, fn item ->
          %{
            id: Ecto.UUID.generate(),
            team_id: close.team_id,
            close_id: close.id,
            evidence_type: item.evidence_type,
            bytes: item.bytes,
            sha256: item.sha256,
            content_type: item.content_type,
            metadata: item.metadata,
            created_at: DateTime.utc_now()
          }
        end)

      {count, _} = Repo.insert_all(Evidence, rows)
      {:ok, count}
    end
  end

  @spec transition(Close.t(), atom(), map()) :: {:ok, atom()} | {:error, term()}
  def transition(%Close{state: state}, event, context \\ %{}),
    do: Lifecycle.transition(state, event, context)

  @spec fetch(Scope.t(), Ecto.UUID.t()) :: {:ok, Close.t()} | {:error, :not_found | :unauthorized}
  def fetch(%Scope{} = scope, close_id) do
    if Scope.team_scoped?(scope) and
         Scope.has_team_role?(scope, [
           :finance_operator,
           :billing_admin,
           :team_admin,
           :auditor,
           :integration_client
         ]) do
      team_id = Scope.team_id!(scope)

      case Repo.one(
             from close in Close, where: close.id == ^close_id and close.team_id == ^team_id
           ) do
        nil -> {:error, :not_found}
        close -> {:ok, close}
      end
    else
      {:error, :unauthorized}
    end
  end

  @spec authorize(Scope.t(), map(), :read | :write) :: :ok | {:error, :unauthorized}
  defdelegate authorize(scope, resource, action), to: Authorization

  defp policy_changeset(policy, attrs) do
    policy
    |> Ecto.Changeset.cast(attrs, [
      :version,
      :effective_from,
      :journal_number,
      :liability_account_number,
      :posting_mode,
      :default_offset_account_number,
      :movement_account_map,
      :post_zero_delta,
      :vat_neutral,
      :settlement_mode,
      :settlement_clearing_account_number,
      :settlement_contra_account_number,
      :created_by
    ])
    |> Ecto.Changeset.validate_required([
      :team_id,
      :version,
      :effective_from,
      :journal_number,
      :liability_account_number,
      :posting_mode
    ])
    |> Ecto.Changeset.validate_number(:version, greater_than: 0)
    |> Ecto.Changeset.validate_inclusion(:posting_mode, PolicyVersion.posting_modes())
    |> Ecto.Changeset.validate_change(:vat_neutral, fn :vat_neutral, value ->
      if value, do: [], else: [vat_neutral: "must be true"]
    end)
    |> validate_settlement_accounts()
    |> Ecto.Changeset.unique_constraint([:team_id, :version])
  end

  # SPEC §9.4.1: the erp_customer_settlement mode needs the accountant-
  # approved clearing and contra accounts before it can be certified.
  defp validate_settlement_accounts(changeset) do
    case Ecto.Changeset.get_field(changeset, :settlement_mode) do
      :erp_customer_settlement ->
        Ecto.Changeset.validate_required(changeset, [
          :settlement_clearing_account_number,
          :settlement_contra_account_number
        ])

      _other ->
        changeset
    end
  end
end
