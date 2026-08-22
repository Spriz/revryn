defmodule BillingCore.Domain.Lifecycles do
  @moduledoc """
  Registry of every named domain lifecycle (BC-US-160, INV-046/047).

  One executable `BillingCore.Domain.StateMachine` per lifecycle is the
  single definition of allowed transitions; this module renders them to
  `docs/architecture/state-machines.md` (Mermaid), and a sync test keeps
  the artifact identical to the code — changing a transition table forces
  a reviewed documentation change.
  """

  alias BillingCore.Domain.StateMachine

  @doc "Every named lifecycle: {slug, title, machine, where it is enforced}."
  @spec all() :: [{String.t(), String.t(), StateMachine.t(), String.t()}]
  def all do
    [
      {"subscription", "Subscription (§11.1)", BillingCore.Contracts.subscription_machine(),
       "BillingCore.Contracts — commands guard transitions before any write"},
      {"invoice-intent", "Invoice intent and ERP synchronization (§11.2)",
       BillingCore.Billing.IntentMachine.machine(),
       "BillingCore.Billing / BillingCore.ERP.Sync — persisted per-intent lifecycle rows"},
      {"durable-operation", "Durable operation (§11.3)", BillingCore.Operations.machine(),
       "BillingCore.Operations — every external effect runs inside one operation"},
      {"credit-grant", "Customer-credit grant projection (§11.4)",
       BillingCore.Credits.grant_machine(),
       "BillingCore.Credits — projection over the append-only subledger"},
      {"customer-credit-close", "Monthly customer-credit close (§11.5, ADR-031)",
       BillingCore.Credits.Close.Lifecycle.machine(),
       "BillingCore.Credits.CloseWorkflow / ClosePosting"}
    ]
  end

  @doc "Renders the reviewed `docs/architecture/state-machines.md` artifact."
  @spec to_markdown() :: String.t()
  def to_markdown do
    sections =
      Enum.map_join(all(), "\n", fn {slug, title, machine, enforcement} ->
        """
        ## #{title}

        Enforced by #{enforcement}. Initial state `#{machine.initial}`;
        terminal states: #{terminals(machine)}.

        ```mermaid
        #{StateMachine.to_mermaid(machine)}
        ```
        <a id="#{slug}"></a>
        """
      end)

    """
    # Domain lifecycle state machines

    Generated from `BillingCore.Domain.Lifecycles` — do not edit by hand.
    Regenerate with:

        mix run --no-start -e 'File.write!("docs/architecture/state-machines.md", BillingCore.Domain.Lifecycles.to_markdown())'

    One executable transition table per lifecycle is the only source of
    allowed transitions (BC-US-160, INV-046). Invalid transitions fail
    deterministically before external side effects, and PostgreSQL — never
    BEAM process lifetime — is authoritative for current state (INV-047).
    Changing a table changes this document, which is reviewed as product
    behavior.

    #{sections}
    """
  end

  defp terminals(machine) do
    case Enum.sort(machine.terminal) do
      [] -> "none"
      terminal -> Enum.map_join(terminal, ", ", &"`#{&1}`")
    end
  end
end
