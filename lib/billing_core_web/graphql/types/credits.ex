defmodule BillingCoreWeb.GraphQL.Types.Credits do
  @moduledoc """
  Customer-credit subledger types (SPEC §14.5 credit capability group,
  BC-US-107/108): team-scoped credit accounts with their append-only grant
  and transaction evidence, plus the audited grant mutation.
  """

  use Absinthe.Schema.Notation

  alias BillingCoreWeb.GraphQL.Errors
  alias BillingCoreWeb.GraphQL.Resolvers

  ## Objects

  @desc "A credit grant — an individual liability movement, never a discount."
  object :credit_grant do
    field :id, non_null(:id)
    field :origin_type, non_null(:string)
    field :origin_id, :id
    field :origin_invoice_line_id, :id
    field :granted_minor, non_null(:money_minor_units)
    field :remaining_minor, non_null(:money_minor_units)
    field :reserved_minor, non_null(:money_minor_units)
    field :currency, non_null(:string)

    field :status, non_null(:string) do
      resolve(&Resolvers.Credits.stringify(:status, &1, &2, &3))
    end

    field :granted_at, non_null(:datetime)
    field :expires_at, :datetime
  end

  @desc "One append-only subledger transaction."
  object :credit_transaction do
    field :id, non_null(:id)

    field :transaction_type, non_null(:string) do
      resolve(&Resolvers.Credits.stringify(:transaction_type, &1, &2, &3))
    end

    field :amount_minor, non_null(:money_minor_units)
    field :currency, non_null(:string)
    field :grant_id, :id
    field :invoice_intent_id, :id
    field :operation_id, :id
    field :reason_code, :string
    field :accounting_effective_on, non_null(:date)
    field :occurred_at, non_null(:datetime)
  end

  @desc "A versioned remaining-credit disposition policy (BC-US-109)."
  object :credit_disposition_policy do
    field :version, non_null(:integer)

    @desc "retain, refund, or expire_after."
    field :policy, non_null(:string) do
      resolve(&Resolvers.Credits.stringify(:policy, &1, &2, &3))
    end

    field :expire_after_days, :integer
    field :effective_from, non_null(:datetime)
  end

  @desc "A team-scoped credit account projection over the append-only ledger."
  object :credit_account do
    field :id, non_null(:id)

    @desc "The organization-level commercial account this projects."
    field :account_id, non_null(:id)
    field :currency, non_null(:string)
    field :available_minor, non_null(:money_minor_units)
    field :reserved_minor, non_null(:money_minor_units)

    field :grants, non_null(list_of(non_null(:credit_grant))) do
      resolve(&Resolvers.Credits.account_grants/3)
    end

    field :transactions, non_null(list_of(non_null(:credit_transaction))) do
      resolve(&Resolvers.Credits.account_transactions/3)
    end

    @desc "The currently effective disposition policy, or null when unset."
    field :disposition_policy, :credit_disposition_policy do
      resolve(&Resolvers.Credits.account_disposition_policy/3)
    end
  end

  ## grantCredit

  input_object :grant_credit_input do
    field :team_id, non_null(:id)
    field :credit_account_id, non_null(:id)

    @desc "unused_prepaid_service, goodwill, external_correction, or manual."
    field :origin_type, non_null(:string)
    field :amount_minor, non_null(:money_minor_units)
    field :currency, non_null(:string)
    field :reason_code, :string
    field :expires_at, :datetime
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :grant_credit_success do
    field :credit_grant, non_null(:credit_grant)
    field :client_mutation_id, non_null(:string)
  end

  union :grant_credit_result do
    types([
      :grant_credit_success,
      :validation_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :grant_credit_success)
    end)
  end

  ## setCreditDispositionPolicy

  input_object :set_credit_disposition_policy_input do
    field :team_id, non_null(:id)
    field :credit_account_id, non_null(:id)

    @desc "retain, refund, or expire_after."
    field :policy, non_null(:string)

    @desc "Required for expire_after."
    field :expire_after_days, :integer
    field :client_mutation_id, non_null(:string)
  end

  object :set_credit_disposition_policy_success do
    field :disposition_policy, non_null(:credit_disposition_policy)
    field :client_mutation_id, non_null(:string)
  end

  union :set_credit_disposition_policy_result do
    types([
      :set_credit_disposition_policy_success,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :set_credit_disposition_policy_success)
    end)
  end
end
