defmodule BillingCoreWeb.DomainComponents do
  @moduledoc """
  Billing-domain UI components shared by the product LiveViews: money and
  service-period rendering, lifecycle state badges, calculation-trace
  expanders, and the team navigation header.

  Money is always integer minor units plus an ISO 4217 currency (INV: no
  floating-point money); `format_money/2` renders it deterministically.
  """

  use Phoenix.Component
  use BillingCoreWeb, :verified_routes

  import BillingCoreWeb.CoreComponents, only: [icon: 1]

  alias BillingCore.Domain.Money

  @doc """
  Renders an integer minor-unit amount with its currency.

      <.money currency="DKK" minor={12_000_000} />
      #=> 120,000.00 DKK
  """
  attr :currency, :string, required: true
  attr :minor, :integer, required: true
  attr :class, :any, default: nil

  def money(assigns) do
    ~H"""
    <span class={["tabular-nums whitespace-nowrap", @class]}>{format_money(@currency, @minor)}</span>
    """
  end

  @doc "Formats integer minor units as a grouped major-unit string with currency."
  @spec format_money(String.t(), integer()) :: String.t()
  def format_money(currency, minor) when is_binary(currency) and is_integer(minor) do
    exponent = Money.exponent(currency)
    {sign, abs_minor} = if minor < 0, do: {"-", -minor}, else: {"", minor}
    digits = abs_minor |> Integer.to_string() |> String.pad_leading(exponent + 1, "0")
    {major, frac} = String.split_at(digits, byte_size(digits) - exponent)
    fraction = if exponent > 0, do: "." <> frac, else: ""
    "#{sign}#{group_thousands(major)}#{fraction} #{currency}"
  end

  defp group_thousands(digits) do
    digits
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &to_string/1)
    |> String.reverse()
  end

  @doc """
  Renders a half-open service period `[start, end_exclusive)` or an em dash
  for point-in-time lines.
  """
  attr :start, :any, default: nil
  attr :end_exclusive, :any, default: nil

  def period(assigns) do
    ~H"""
    <span :if={@start} class="whitespace-nowrap tabular-nums">
      {@start} → {@end_exclusive}
    </span>
    <span :if={!@start} class="opacity-50">—</span>
    """
  end

  @doc "Lifecycle/status badge with severity-based coloring."
  attr :state, :any, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def state_badge(assigns) do
    state = to_string(assigns.state)

    assigns =
      assigns
      |> assign(:label, String.replace(state, "_", " "))
      |> assign(:color, badge_color(state))

    ~H"""
    <span class={["badge badge-sm", @color, @class]} {@rest}>{@label}</span>
    """
  end

  defp badge_color(state)
       when state in ~w(active succeeded erp_booked booked published valid approved closed),
       do: "badge-success"

  defp badge_color(state)
       when state in ~w(pending sync_pending booking_pending scheduled queued executing
                       retry_scheduled reconciling paused pending_cancellation draft
                       unvalidated outcome_unknown syncing credit_required action_required warn),
       do: "badge-warning"

  defp badge_color(state)
       when state in ~w(failed sync_error blocked cancelled invalid reconciliation_failed fail),
       do: "badge-error"

  defp badge_color(state) when state in ~w(frozen erp_draft open ready pass awaiting_approval),
    do: "badge-info"

  defp badge_color(_state), do: "badge-ghost"

  @doc """
  Expandable, human-readable rendering of a calculation trace (BC-US-110):
  JSON is pretty-printed inside a `<details>` element.
  """
  attr :id, :string, required: true
  attr :trace, :map, required: true
  attr :label, :string, default: "Calculation trace"

  def trace(assigns) do
    assigns = assign(assigns, :json, Jason.encode!(assigns.trace, pretty: true))

    ~H"""
    <details id={@id} class="text-xs">
      <summary class="cursor-pointer select-none opacity-70 hover:opacity-100">{@label}</summary>
      <pre class="mt-1 max-h-72 overflow-auto rounded bg-base-200 p-2"><code>{@json}</code></pre>
    </details>
    """
  end

  @doc "Truncated monospace hash rendering with full value on hover."
  attr :value, :string, required: true

  def hash(assigns) do
    ~H"""
    <code :if={@value} class="font-mono text-xs" title={@value}>{String.slice(@value, 0, 12)}…</code>
    """
  end

  @doc """
  Breadcrumb-ish team header plus section navigation, rendered at the top of
  every team-scoped page.
  """
  attr :team, :map, required: true
  attr :organization, :map, default: nil
  attr :active, :atom, required: true

  def team_nav(assigns) do
    ~H"""
    <div class="mb-6 space-y-3">
      <nav class="text-sm breadcrumbs" aria-label="Breadcrumb">
        <ul>
          <li><.link navigate={~p"/"}>Teams</.link></li>
          <li :if={@organization}>{@organization.name}</li>
          <li class="font-semibold">{@team.name}</li>
        </ul>
      </nav>
      <nav class="tabs tabs-border" id="team-nav">
        <.link
          :for={{key, label, path} <- team_nav_items(@team)}
          navigate={path}
          class={["tab", @active == key && "tab-active"]}
          aria-current={@active == key && "page"}
        >
          {label}
        </.link>
      </nav>
    </div>
    """
  end

  defp team_nav_items(team) do
    [
      {:overview, "Overview", ~p"/teams/#{team.id}"},
      {:customers, "Customers", ~p"/teams/#{team.id}/customers"},
      {:catalog, "Catalog", ~p"/teams/#{team.id}/catalog"},
      {:subscriptions, "Subscriptions", ~p"/teams/#{team.id}/subscriptions"},
      {:billing_runs, "Billing runs", ~p"/teams/#{team.id}/billing-runs"},
      {:operations, "Operations", ~p"/teams/#{team.id}/operations"},
      {:settings, "Settings", ~p"/teams/#{team.id}/settings"}
    ]
  end

  @doc "Centered empty-state block for lists without content yet."
  attr :id, :string, default: nil
  slot :inner_block, required: true
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-dashed border-base-300 px-6 py-10 text-center">
      <.icon name="hero-inbox" class="mx-auto size-8 opacity-30" />
      <p class="mt-2 text-sm opacity-70">{render_slot(@inner_block)}</p>
      <div :if={@action != []} class="mt-4">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc "Formats a UTC timestamp (or nil) as `YYYY-mm-dd HH:MM UTC`."
  @spec format_dt(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def format_dt(nil), do: nil
  def format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  def format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
