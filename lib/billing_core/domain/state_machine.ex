defmodule BillingCore.Domain.StateMachine do
  @moduledoc """
  Deliberately small, pure state-machine definition (SPEC §11.5–11.6,
  INV-046/047).

  A definition is plain data: states, events, a transition table, optional
  guards, and terminal states. Persistence, locking, audit evidence, and
  side effects belong to the owning Ecto context — this module only answers
  "is this transition legal, and what is the next state?" and can render the
  lifecycle as Mermaid for feature documentation.

  ## Example

      @machine StateMachine.new(:subscription,
                 initial: :scheduled,
                 transitions: [
                   {:scheduled, :start, :active},
                   {:scheduled, :cancel, :cancelled},
                   {:active, :pause, :paused, guard: :no_open_billing_run}
                 ],
                 terminal: [:cancelled]
               )

      StateMachine.transition(@machine, :scheduled, :start, ctx)
      #=> {:ok, :active}
  """

  defmodule TransitionError do
    @moduledoc "Structured transition failure."
    defstruct [:machine, :from, :event, :reason, :guard]

    @type t :: %__MODULE__{
            machine: atom(),
            from: atom(),
            event: atom(),
            reason: :illegal_transition | :terminal_state | :guard_rejected,
            guard: term()
          }
  end

  @enforce_keys [:name, :initial, :table, :terminal]
  defstruct [:name, :initial, :table, :terminal, guards: %{}]

  @type state :: atom()
  @type event :: atom()
  @type guard_fun :: (map() -> :ok | {:error, term()})
  @type t :: %__MODULE__{
          name: atom(),
          initial: state(),
          table: %{{state(), event()} => {state(), atom() | nil}},
          terminal: MapSet.t(state()),
          guards: %{atom() => guard_fun()}
        }

  @spec new(atom(), keyword()) :: t()
  def new(name, opts) do
    transitions = Keyword.fetch!(opts, :transitions)
    initial = Keyword.fetch!(opts, :initial)
    terminal = opts |> Keyword.get(:terminal, []) |> MapSet.new()
    guards = opts |> Keyword.get(:guards, []) |> Map.new()

    table =
      Map.new(transitions, fn
        {from, event, to} -> {{from, event}, {to, nil}}
        {from, event, to, guard: guard} -> {{from, event}, {to, guard}}
      end)

    %__MODULE__{name: name, initial: initial, table: table, terminal: terminal, guards: guards}
  end

  @doc """
  Resolves a transition. Returns `{:ok, next_state}` or a structured error.
  Guards receive the caller-supplied context map.
  """
  @spec transition(t(), state(), event(), map()) :: {:ok, state()} | {:error, TransitionError.t()}
  def transition(%__MODULE__{} = m, from, event, ctx \\ %{}) do
    cond do
      MapSet.member?(m.terminal, from) ->
        {:error, error(m, from, event, :terminal_state)}

      not Map.has_key?(m.table, {from, event}) ->
        {:error, error(m, from, event, :illegal_transition)}

      true ->
        {to, guard} = Map.fetch!(m.table, {from, event})

        case run_guard(m, guard, ctx) do
          :ok -> {:ok, to}
          {:error, reason} -> {:error, %{error(m, from, event, :guard_rejected) | guard: reason}}
        end
    end
  end

  @spec legal?(t(), state(), event()) :: boolean()
  def legal?(%__MODULE__{} = m, from, event) do
    Map.has_key?(m.table, {from, event}) and not MapSet.member?(m.terminal, from)
  end

  @spec states(t()) :: [state()]
  def states(%__MODULE__{} = m) do
    m.table
    |> Enum.flat_map(fn {{from, _e}, {to, _g}} -> [from, to] end)
    |> Enum.concat([m.initial])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec events(t()) :: [event()]
  def events(%__MODULE__{} = m) do
    m.table |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
  end

  @spec terminal?(t(), state()) :: boolean()
  def terminal?(%__MODULE__{} = m, state), do: MapSet.member?(m.terminal, state)

  @doc "Events legal from `state`, for UI affordances and docs."
  @spec legal_events(t(), state()) :: [event()]
  def legal_events(%__MODULE__{} = m, state) do
    if MapSet.member?(m.terminal, state) do
      []
    else
      m.table
      |> Map.keys()
      |> Enum.filter(&(elem(&1, 0) == state))
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort()
    end
  end

  @doc "Mermaid `stateDiagram-v2` source for feature documentation (SPEC §11.5)."
  @spec to_mermaid(t()) :: String.t()
  def to_mermaid(%__MODULE__{} = m) do
    transitions =
      m.table
      |> Enum.sort_by(fn {{from, event}, {to, _}} -> {from, to, event} end)
      |> Enum.map(fn {{from, event}, {to, guard}} ->
        label = if guard, do: "#{event} [#{guard}]", else: "#{event}"
        "  #{from} --> #{to}: #{label}"
      end)

    terminals =
      m.terminal
      |> Enum.sort()
      |> Enum.map(fn s -> "  #{s} --> [*]" end)

    Enum.join(
      ["stateDiagram-v2", "  [*] --> #{m.initial}"] ++ transitions ++ terminals,
      "\n"
    )
  end

  defp run_guard(_m, nil, _ctx), do: :ok

  defp run_guard(%__MODULE__{} = m, guard, ctx) do
    case Map.fetch(m.guards, guard) do
      {:ok, fun} -> fun.(ctx)
      :error -> raise ArgumentError, "state machine #{m.name} has no guard #{inspect(guard)}"
    end
  end

  defp error(m, from, event, reason) do
    %TransitionError{machine: m.name, from: from, event: event, reason: reason}
  end
end
