defmodule BillingCoreWeb.GraphQL.CreditCloses.Types do
  @moduledoc """
  Monthly customer-credit close types (SPEC §14.5, BC-US-163…165,
  BC-TASK-104): the aggregate subledger→general-ledger bridge, its posting
  policy, movement roll-up, immutable evidence, and typed mutation results.

  All fields resolve through the same `BillingCore.Credits.CloseWorkflow`
  commands the LiveView surface uses.
  """

  use Absinthe.Schema.Notation

  alias BillingCoreWeb.GraphQL.CreditCloses.Resolvers
  alias BillingCoreWeb.GraphQL.Errors

  ## Objects

  @desc "An accountant-approved posting policy version for monthly closes."
  object :credit_close_policy do
    field :id, non_null(:id)
    field :version, non_null(:integer)
    field :effective_from, non_null(:date)
    field :journal_number, non_null(:integer)
    field :liability_account_number, non_null(:integer)

    field :posting_mode, non_null(:string) do
      resolve(&Resolvers.stringify(:posting_mode, &1, &2, &3))
    end

    field :default_offset_account_number, :integer
    field :post_zero_delta, non_null(:boolean)
    field :vat_neutral, non_null(:boolean)

    @desc "SPEC §9.4.1: none, erp_customer_settlement, or external_reference."
    field :settlement_mode, non_null(:string) do
      resolve(&Resolvers.stringify(:settlement_mode, &1, &2, &3))
    end

    field :settlement_clearing_account_number, :integer
    field :settlement_contra_account_number, :integer
  end

  @desc "One receivable settlement opened by one credit application (SPEC §9.4.1)."
  object :credit_settlement do
    field :id, non_null(:id)
    field :invoice_intent_id, non_null(:id)
    field :credit_account_id, non_null(:id)
    field :currency, non_null(:string)
    field :amount_minor, non_null(:integer)

    field :mode, non_null(:string) do
      resolve(&Resolvers.stringify(:mode, &1, &2, &3))
    end

    field :state, non_null(:string) do
      resolve(&Resolvers.stringify(:state, &1, &2, &3))
    end

    field :external_reference, :string
    field :external_voucher_number, :string
    field :reconciled_at, :datetime
    field :created_at, non_null(:datetime)
  end

  @desc "Movement-type roll-up inside one close period."
  object :credit_close_movement do
    field :movement_type, non_null(:string) do
      resolve(&Resolvers.stringify(:movement_type, &1, &2, &3))
    end

    field :amount_minor, non_null(:money_minor_units)
    field :liability_effect_minor, non_null(:money_minor_units)
    field :transaction_count, non_null(:integer)
  end

  @desc "Metadata of one immutable evidence file (never inline bytes)."
  object :credit_close_evidence_meta do
    field :evidence_type, non_null(:string) do
      resolve(&Resolvers.stringify(:evidence_type, &1, &2, &3))
    end

    field :sha256, non_null(:string)
    field :content_type, non_null(:string)
    field :byte_size, non_null(:integer)
  end

  @desc "One immutable evidence file with its exact bytes, base64-encoded."
  object :credit_close_report do
    field :evidence_type, non_null(:string)
    field :sha256, non_null(:string)
    field :content_type, non_null(:string)
    field :content_base64, non_null(:string)
  end

  @desc "One monthly customer-credit close (§11.5 lifecycle)."
  object :credit_close do
    field :id, non_null(:id)
    field :currency, non_null(:string)
    field :period_start, non_null(:date)
    field :period_end_exclusive, non_null(:date)
    field :transaction_cutoff, non_null(:datetime)

    @desc "regular, reversal, or replacement (ADR-031 compensating closes)."
    field :close_kind, non_null(:string) do
      resolve(&Resolvers.stringify(:close_kind, &1, &2, &3))
    end

    @desc "For a correction close: the close it corrects."
    field :reversal_of_close_id, :id

    @desc "Correction closes referencing this close, oldest first."
    field :corrections, non_null(list_of(non_null(:credit_close))) do
      resolve(&Resolvers.close_corrections/3)
    end

    @desc "Current §11.5 state (open, ready, approved, posting, reconciled, closed, ...)."
    field :state, non_null(:string) do
      resolve(&Resolvers.stringify(:state, &1, &2, &3))
    end

    field :opening_minor, :money_minor_units
    field :closing_minor, :money_minor_units
    field :net_change_minor, :money_minor_units
    field :economic_liability_line_minor, :money_minor_units
    field :ledger_transaction_count, :integer
    field :report_sha256, :string
    field :closed_at, :datetime

    field :movements, non_null(list_of(non_null(:credit_close_movement))) do
      resolve(&Resolvers.close_movements/3)
    end

    field :evidence, non_null(list_of(non_null(:credit_close_evidence_meta))) do
      resolve(&Resolvers.close_evidence/3)
    end

    @desc "Voucher number of the posted aggregate document, once posted."
    field :external_voucher_number, :string do
      resolve(&Resolvers.close_voucher_number/3)
    end

    @desc "One stored immutable evidence file with its exact bytes."
    field :report, :credit_close_report do
      arg(:evidence_type, non_null(:string))
      resolve(&Resolvers.close_report/3)
    end
  end

  ## createCreditClosePolicy

  input_object :create_credit_close_policy_input do
    field :team_id, non_null(:id)
    field :effective_from, non_null(:date)
    field :journal_number, non_null(:integer)
    field :liability_account_number, non_null(:integer)
    field :default_offset_account_number, non_null(:integer)
    field :post_zero_delta, :boolean
    field :vat_neutral, :boolean

    @desc "none (default — blocks automatic credit application), erp_customer_settlement, or external_reference."
    field :settlement_mode, :string
    field :settlement_clearing_account_number, :integer
    field :settlement_contra_account_number, :integer
    field :client_mutation_id, non_null(:string)
  end

  object :create_credit_close_policy_success do
    field :policy, non_null(:credit_close_policy)
    field :client_mutation_id, non_null(:string)
  end

  union :create_credit_close_policy_result do
    types([
      :create_credit_close_policy_success,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_credit_close_policy_success)
    end)
  end

  ## generateCreditClose

  input_object :generate_credit_close_input do
    field :team_id, non_null(:id)
    field :currency, non_null(:string)

    @desc "Any date inside the close month; the calendar month is frozen."
    field :period_date, non_null(:date)

    @desc "Required only for the very first close of a currency (zero is valid)."
    field :bootstrap_opening_minor, :money_minor_units

    @desc "Defaults to the latest policy version."
    field :policy_version_id, :id
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :generate_credit_close_success do
    field :credit_close, non_null(:credit_close)
    field :client_mutation_id, non_null(:string)
  end

  union :generate_credit_close_result do
    types([
      :generate_credit_close_success,
      :validation_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :generate_credit_close_success)
    end)
  end

  ## approveCreditClose

  input_object :approve_credit_close_input do
    field :team_id, non_null(:id)
    field :credit_close_id, non_null(:id)
    field :reason, :string
    field :client_mutation_id, non_null(:string)
  end

  object :approve_credit_close_success do
    field :credit_close, non_null(:credit_close)
    field :client_mutation_id, non_null(:string)
  end

  union :approve_credit_close_result do
    types([
      :approve_credit_close_success,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :approve_credit_close_success)
    end)
  end

  ## requestCreditClosePosting

  input_object :request_credit_close_posting_input do
    field :team_id, non_null(:id)
    field :credit_close_id, non_null(:id)
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :request_credit_close_posting_success do
    field :operation, non_null(:operation)
    field :credit_close, non_null(:credit_close)
    field :client_mutation_id, non_null(:string)
  end

  union :request_credit_close_posting_result do
    types([
      :request_credit_close_posting_success,
      :validation_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :request_credit_close_posting_success)
    end)
  end

  ## requestCreditCloseReversal

  input_object :request_credit_close_reversal_input do
    field :team_id, non_null(:id)
    field :credit_close_id, non_null(:id)

    @desc "Recorded correction reason — required for the audit trail."
    field :reason, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :request_credit_close_reversal_success do
    @desc "The frozen reversal close carrying the mirrored bridge."
    field :reversal_close, non_null(:credit_close)
    field :client_mutation_id, non_null(:string)
  end

  union :request_credit_close_reversal_result do
    types([
      :request_credit_close_reversal_success,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :request_credit_close_reversal_success)
    end)
  end

  ## generateCreditCloseReplacement

  input_object :generate_credit_close_replacement_input do
    field :team_id, non_null(:id)

    @desc "The reversed close whose period is being reposted."
    field :credit_close_id, non_null(:id)

    @desc "The corrected posting-policy version."
    field :policy_version_id, non_null(:id)

    @desc "Recorded correction reason — required for the audit trail."
    field :reason, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :generate_credit_close_replacement_success do
    field :replacement_close, non_null(:credit_close)
    field :client_mutation_id, non_null(:string)
  end

  union :generate_credit_close_replacement_result do
    types([
      :generate_credit_close_replacement_success,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :generate_credit_close_replacement_success)
    end)
  end

  ## closeCreditPeriod

  input_object :close_credit_period_input do
    field :team_id, non_null(:id)
    field :credit_close_id, non_null(:id)
    field :client_mutation_id, non_null(:string)
  end

  object :close_credit_period_success do
    field :credit_close, non_null(:credit_close)
    field :client_mutation_id, non_null(:string)
  end

  union :close_credit_period_result do
    types([
      :close_credit_period_success,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :close_credit_period_success)
    end)
  end

  ## recordExternalSettlement

  input_object :record_external_settlement_input do
    field :team_id, non_null(:id)
    field :settlement_id, non_null(:id)

    @desc "The authoritative external receivables system's settlement reference."
    field :external_reference, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :record_external_settlement_success do
    field :settlement, non_null(:credit_settlement)
    field :client_mutation_id, non_null(:string)
  end

  union :record_external_settlement_result do
    types([
      :record_external_settlement_success,
      :validation_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :record_external_settlement_success)
    end)
  end
end
