defmodule BillingCoreWeb.DemoLive.Show do
  @moduledoc """
  Guided demo workspace overview for BC-US-166.

  Journey phases render exclusively from durable domain rows derived by
  `BillingCore.Demo.Scenario` — a phase advances only when its real Revryn
  artifact exists, and every completed phase links to the ordinary product
  surface holding that artifact. While the provider is doing asynchronous
  work the page re-derives the journey on a short timer.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Demo
  alias BillingCore.Demo.Scenario

  @refresh_interval 2_000
  @pending_states [:sync_pending, :booking_pending]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@scope}>
      <div class={["mx-auto max-w-6xl space-y-8 pb-12"]} id="demo-workspace">
        <nav
          aria-label="Breadcrumb"
          class={["flex items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400"]}
        >
          <.link navigate={~p"/"} class={["transition hover:text-zinc-950 dark:hover:text-zinc-50"]}>
            Workspaces
          </.link>
          <.icon name="hero-chevron-right" class="size-3.5" />
          <span aria-current="page" class={["font-medium text-zinc-800 dark:text-zinc-200"]}>
            Guided workspace
          </span>
        </nav>

        <header class={[
          "grid gap-7 rounded-3xl border border-zinc-200 bg-white p-7 shadow-[0_24px_70px_-48px_rgba(24,24,27,0.55)] lg:grid-cols-[1fr_auto] lg:items-end sm:p-9 dark:border-zinc-800 dark:bg-zinc-950"
        ]}>
          <div>
            <div class={["flex flex-wrap items-center gap-3"]}>
              <span class={[
                "inline-flex items-center gap-2 rounded-full border border-amber-200 bg-amber-50 px-3 py-1 text-xs font-semibold text-amber-800 dark:border-amber-900 dark:bg-amber-950/50 dark:text-amber-300"
              ]}>
                <span class={["size-1.5 rounded-full bg-amber-500"]} />
                Synthetic company · isolated books
              </span>
              <span class={["text-xs font-medium text-zinc-500 dark:text-zinc-400"]}>
                Scenario {@workspace.scenario_version} · generation {@workspace.generation}
              </span>
            </div>
            <h1 class={[
              "mt-5 text-3xl font-semibold tracking-[-0.025em] text-zinc-950 sm:text-4xl dark:text-zinc-50"
            ]}>
              Northstar Studio ApS
            </h1>
            <p class={["mt-3 max-w-2xl text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
              One annual subscription, one customer-credit movement, and one monthly liability
              close. Each step exposes the input, calculation, durable operation, ERP result,
              and read-back evidence that connects them.
            </p>
          </div>

          <div class={["flex flex-col items-start gap-2 lg:items-end"]}>
            <span class={["text-xs text-zinc-500 dark:text-zinc-400"]}>
              Started {format_dt(@workspace.started_at)}
            </span>
            <button
              id="reset-demo"
              type="button"
              phx-click="reset_demo"
              data-confirm="Reset the guided workspace? Revryn will archive this generation and create a clean one. Existing evidence is retained."
              phx-disable-with="Preparing a clean generation…"
              class={[
                "inline-flex min-h-10 items-center gap-2 rounded-xl border border-zinc-300 bg-white px-4 text-sm font-semibold text-zinc-700 transition hover:border-zinc-400 hover:bg-zinc-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-600 disabled:cursor-wait disabled:opacity-60 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:border-zinc-600 dark:hover:bg-zinc-800"
              ]}
            >
              <.icon name="hero-arrow-path" class="size-4" /> Reset sample books
            </button>
          </div>
        </header>

        <section
          id="demo-connection-proof"
          class={[
            "grid gap-5 rounded-2xl border border-emerald-200 bg-emerald-50/50 p-6 lg:grid-cols-[0.9fr_1.1fr] dark:border-emerald-900 dark:bg-emerald-950/20"
          ]}
        >
          <div class={["flex gap-4"]}>
            <span class={[
              "flex size-11 shrink-0 items-center justify-center rounded-xl bg-emerald-700 text-white dark:bg-emerald-500 dark:text-emerald-950"
            ]}>
              <.icon name="hero-check" class="size-5" />
            </span>
            <div>
              <p class={[
                "text-xs font-semibold uppercase tracking-[0.17em] text-emerald-800 dark:text-emerald-300"
              ]}>
                First proof established
              </p>
              <h2 class={["mt-2 text-lg font-semibold text-zinc-950 dark:text-zinc-50"]}>
                A private ERP instance passed preflight
              </h2>
              <p class={["mt-2 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                This connection uses the same adapter contract as e-conomic. Its state is scoped to
                this workspace and read back after every external effect.
              </p>
            </div>
          </div>

          <dl class={["grid gap-3 sm:grid-cols-2"]} id="demo-connection-details">
            <div class={[
              "rounded-xl border border-emerald-100 bg-white/80 p-4 dark:border-emerald-900 dark:bg-zinc-950/70"
            ]}>
              <dt class={["text-xs font-medium text-zinc-500 dark:text-zinc-400"]}>
                Provider boundary
              </dt>
              <dd class={["mt-1 font-mono text-sm font-semibold text-zinc-900 dark:text-zinc-100"]}>
                Demo ERP
              </dd>
            </div>
            <div class={[
              "rounded-xl border border-emerald-100 bg-white/80 p-4 dark:border-emerald-900 dark:bg-zinc-950/70"
            ]}>
              <dt class={["text-xs font-medium text-zinc-500 dark:text-zinc-400"]}>
                Preflight status
              </dt>
              <dd class={["mt-1 text-sm font-semibold text-emerald-800 dark:text-emerald-300"]}>
                {connection_status(@connection.status)}
              </dd>
            </div>
            <div class={[
              "rounded-xl border border-emerald-100 bg-white/80 p-4 sm:col-span-2 dark:border-emerald-900 dark:bg-zinc-950/70"
            ]}>
              <dt class={["text-xs font-medium text-zinc-500 dark:text-zinc-400"]}>Isolation key</dt>
              <dd class={["mt-1 break-all font-mono text-xs text-zinc-700 dark:text-zinc-300"]}>
                {@connection.id}
              </dd>
            </div>
          </dl>
        </section>

        <section aria-labelledby="journey-title" class={["grid gap-7 lg:grid-cols-[0.68fr_1.32fr]"]}>
          <div>
            <p class={[
              "text-xs font-semibold uppercase tracking-[0.2em] text-zinc-500 dark:text-zinc-400"
            ]}>
              Cause and effect
            </p>
            <h2
              id="journey-title"
              class={["mt-2 text-2xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50"]}
            >
              The accounting story
            </h2>
            <p class={["mt-3 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
              Nothing below is marked complete until its real Revryn artifact exists. Start with the
              commercial model; the later accounting evidence builds on those exact inputs.
            </p>
          </div>

          <ol
            id="demo-journey"
            class={[
              "relative space-y-3 before:absolute before:bottom-7 before:left-[1.3rem] before:top-7 before:w-px before:bg-zinc-200 dark:before:bg-zinc-800"
            ]}
          >
            <.journey_phase
              id="demo-phase-connection"
              number="1"
              title="Provider boundary"
              done={true}
              status="Ready"
              status_tone={:done}
            >
              <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                Isolated Demo ERP, capabilities, journal access, and read-back behavior verified.
              </p>
            </.journey_phase>

            <.journey_phase
              id="demo-phase-commercial"
              number="2"
              title="Commercial source"
              done={@journey.commercial.state == :complete}
              status={commercial_status(@journey.commercial.state)}
              status_tone={if(@journey.commercial.state == :complete, do: :done, else: :next)}
            >
              <%= if @journey.commercial.state == :complete do %>
                <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                  Northstar Platform is published as an annual prepaid plan, and
                  Fjordlys Analytics ApS subscribed on {format_date(@journey.anchor_date)} —
                  the exact inputs the invoice will trace back to.
                </p>
                <div class={["mt-3 flex flex-wrap gap-x-5 gap-y-1.5"]}>
                  <.artifact_link
                    id="demo-link-plan-version"
                    navigate={
                      ~p"/teams/#{@team.id}/catalog/plan-versions/#{@journey.commercial.refs["plan_version_id"]}"
                    }
                    label="Published plan version"
                  />
                  <.artifact_link
                    id="demo-link-customer"
                    navigate={
                      ~p"/teams/#{@team.id}/customers/#{@journey.commercial.refs["customer_id"]}"
                    }
                    label="Customer"
                  />
                  <.artifact_link
                    id="demo-link-subscription"
                    navigate={
                      ~p"/teams/#{@team.id}/subscriptions/#{@journey.commercial.refs["subscription_id"]}"
                    }
                    label="Subscription"
                  />
                </div>
              <% else %>
                <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                  Create the product, annual plan, customer, and subscription that explain why an
                  invoice will exist. Revryn runs the same catalog and contract commands a real
                  team uses — nothing is seeded behind the scenes.
                </p>
                <p
                  :if={@journey.commercial.state == :partial}
                  class={["mt-2 text-xs leading-5 text-amber-700 dark:text-amber-400"]}
                >
                  An earlier attempt was interrupted. Continuing reuses what already exists and
                  creates only the missing pieces.
                </p>
                <button
                  id="demo-build-commercial"
                  type="button"
                  phx-click="build_commercial"
                  phx-disable-with="Creating the commercial model…"
                  class={[
                    "mt-3 inline-flex min-h-10 items-center gap-2 rounded-xl bg-emerald-700 px-4 text-sm font-semibold text-white transition hover:bg-emerald-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-600 disabled:cursor-wait disabled:opacity-60 dark:bg-emerald-600 dark:hover:bg-emerald-500"
                  ]}
                >
                  <.icon name="hero-sparkles" class="size-4" />
                  {if @journey.commercial.state == :partial,
                    do: "Resume creating the commercial model",
                    else: "Create the commercial model"}
                </button>
              <% end %>
            </.journey_phase>

            <.journey_phase
              id="demo-phase-invoice"
              number="3"
              title="Invoice and ERP draft"
              done={@journey.invoice.state == :erp_booked}
              status={invoice_status(@journey.invoice.state)}
              status_tone={invoice_status_tone(@journey.invoice.state)}
            >
              <%= if @journey.invoice.state == :locked do %>
                <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                  Preview exact service periods, freeze the intent, create a provider draft, and
                  reconcile the read-back copy. Available once the commercial model exists.
                </p>
              <% else %>
                <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                  {invoice_body(@journey.invoice.state)}
                </p>

                <ul id="demo-invoice-milestones" class={["mt-3 space-y-1.5"]}>
                  <.milestone
                    reached={invoice_rank(@journey.invoice.state) >= 1}
                    active={@journey.invoice.state == :not_started}
                    label="Immutable intent frozen from the preview"
                  />
                  <.milestone
                    reached={invoice_rank(@journey.invoice.state) >= 2}
                    active={@journey.invoice.state in [:frozen, :sync_pending, :sync_error]}
                    label="Provider draft created and reconciled by read-back"
                  />
                  <.milestone
                    reached={invoice_rank(@journey.invoice.state) >= 3}
                    active={@journey.invoice.state == :erp_draft}
                    label="Reconciled draft approved for booking"
                  />
                  <.milestone
                    reached={invoice_rank(@journey.invoice.state) >= 4}
                    active={@journey.invoice.state in [:approved, :booking_pending]}
                    label="Booked document reconciled with accrual dates"
                  />
                </ul>

                <div
                  :if={@journey.invoice.refs["external_draft_number"]}
                  id="demo-invoice-evidence"
                  class={[
                    "mt-3 flex flex-wrap gap-x-5 gap-y-1 text-xs text-zinc-600 dark:text-zinc-300"
                  ]}
                >
                  <span>
                    Draft
                    <span class={["font-mono font-semibold"]}>{@journey.invoice.refs[
                      "external_draft_number"
                    ]}</span>
                  </span>
                  <span :if={@journey.invoice.refs["external_booked_number"]}>
                    Booked
                    <span class={["font-mono font-semibold"]}>{@journey.invoice.refs[
                      "external_booked_number"
                    ]}</span>
                  </span>
                  <span :if={@journey.invoice.refs["net_amount_minor"]}>
                    {format_money(
                      @journey.invoice.refs["currency"],
                      @journey.invoice.refs["net_amount_minor"]
                    )}
                  </span>
                </div>

                <.invoice_action
                  state={@journey.invoice.state}
                  team_id={@team.id}
                  subscription_id={@journey.commercial.refs["subscription_id"]}
                  intent_id={@journey.invoice.refs["invoice_intent_id"]}
                />

                <div :if={@journey.invoice.state == :frozen} class={["mt-2"]}>
                  <button
                    id="demo-inject-failure"
                    type="button"
                    phx-click="inject_failure"
                    phx-value-kind="validation"
                    class={[
                      "text-xs font-medium text-zinc-500 underline decoration-dotted underline-offset-2 transition hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-200"
                    ]}
                  >
                    Curious how failures are handled? Simulate a provider rejection first.
                  </button>
                  <details class={["mt-1"]}>
                    <summary class={[
                      "cursor-pointer text-xs text-zinc-400 transition hover:text-zinc-600 dark:hover:text-zinc-300"
                    ]}>
                      More failure drills
                    </summary>
                    <div class={["mt-1 flex flex-wrap gap-3"]}>
                      <button
                        :for={
                          {kind, label} <- [
                            {"transient", "Self-healing blip"},
                            {"authorization", "Revoked credentials"},
                            {"terminal", "Non-retryable defect"}
                          ]
                        }
                        id={"demo-inject-failure-#{kind}"}
                        type="button"
                        phx-click="inject_failure"
                        phx-value-kind={kind}
                        class={[
                          "text-xs text-zinc-500 underline decoration-dotted underline-offset-2 transition hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-200"
                        ]}
                      >
                        {label}
                      </button>
                    </div>
                  </details>
                </div>

                <p
                  :if={@journey.invoice.state == :sync_error}
                  class={["mt-2 text-xs leading-5 text-amber-700 dark:text-amber-400"]}
                  id="demo-failure-explainer"
                >
                  Nothing was lost: the durable operation kept the provider's exact rejection,
                  no partial draft exists, and retrying reuses the same operation key — the
                  provider is searched before anything is created again.
                </p>
              <% end %>
            </.journey_phase>

            <.journey_phase
              id="demo-phase-credit"
              number="4"
              title="Customer-credit subledger"
              done={@journey.credit.state == :complete}
              status={credit_status(@journey.credit.state)}
              status_tone={credit_status_tone(@journey.credit.state)}
            >
              <%= case @journey.credit.state do %>
                <% :locked -> %>
                  <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                    Record the customer's individual credit movement without turning it into a
                    discount. Available once the first invoice is booked and reconciled.
                  </p>
                <% :complete -> %>
                  <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                    The goodwill credit is an individual, immutable movement in the detailed
                    subledger — a liability Northstar owes Fjordlys, not a discount on a line.
                    The monthly close will aggregate it into one auditable voucher.
                  </p>
                  <div
                    id="demo-credit-evidence"
                    class={[
                      "mt-3 flex flex-wrap gap-x-5 gap-y-1 text-xs text-zinc-600 dark:text-zinc-300"
                    ]}
                  >
                    <span>
                      Goodwill grant {format_money(
                        @journey.credit.refs["currency"],
                        @journey.credit.refs["granted_minor"]
                      )}
                    </span>
                    <span>
                      Granted <span class={["font-mono"]}>{@journey.credit.refs["granted_at"]}</span>
                    </span>
                  </div>
                  <div class={["mt-3"]}>
                    <.artifact_link
                      id="demo-link-credit"
                      navigate={
                        ~p"/teams/#{@team.id}/customers/#{@journey.commercial.refs["customer_id"]}"
                      }
                      label="Inspect the credit subledger on the customer"
                    />
                  </div>
                <% _not_started -> %>
                  <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                    Northstar agreed a DKK 2,500.00 goodwill credit with Fjordlys Analytics after
                    a service incident. Recording it creates a commercial account, links it to
                    the customer, and posts one individual grant into the credit subledger —
                    never a discount hidden inside a price.
                  </p>
                  <button
                    id="demo-grant-credit"
                    type="button"
                    phx-click="grant_credit"
                    phx-disable-with="Recording the credit movement…"
                    class={[
                      "mt-3 inline-flex min-h-10 items-center gap-2 rounded-xl bg-emerald-700 px-4 text-sm font-semibold text-white transition hover:bg-emerald-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-600 disabled:cursor-wait disabled:opacity-60 dark:bg-emerald-600 dark:hover:bg-emerald-500"
                    ]}
                  >
                    <.icon name="hero-banknotes" class="size-4" /> Record the goodwill credit
                  </button>
              <% end %>
            </.journey_phase>

            <.journey_phase
              id="demo-phase-close"
              number="5"
              title="Aggregate liability close"
              done={@journey.close.state == :closed}
              status={close_status(@journey.close.state)}
              status_tone={close_status_tone(@journey.close.state)}
            >
              <%= if @journey.close.state == :locked do %>
                <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                  Freeze the ledger bridge, post one aggregate voucher, attach the report, and
                  compare authoritative read-back. Available once the credit movement exists.
                </p>
              <% else %>
                <p class={["mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                  {close_body(@journey.close.state)}
                </p>

                <ul id="demo-close-milestones" class={["mt-3 space-y-1.5"]}>
                  <.milestone
                    reached={close_rank(@journey.close.state) >= 1}
                    active={@journey.close.state in [:not_started, :generating, :generation_failed]}
                    label="Deterministic close frozen with exact report evidence"
                  />
                  <.milestone
                    reached={close_rank(@journey.close.state) >= 2}
                    active={@journey.close.state == :ready}
                    label="Exact report hash approved by finance"
                  />
                  <.milestone
                    reached={close_rank(@journey.close.state) >= 3}
                    active={@journey.close.state in [:approved, :posting, :mismatch]}
                    label="Aggregate voucher posted, report attached, read-back reconciled"
                  />
                  <.milestone
                    reached={close_rank(@journey.close.state) >= 4}
                    active={@journey.close.state == :reconciled}
                    label="Period accepted as authoritative history"
                  />
                </ul>

                <div
                  :if={@journey.close.refs["closing_minor"]}
                  id="demo-close-evidence"
                  class={[
                    "mt-3 flex flex-wrap gap-x-5 gap-y-1 text-xs text-zinc-600 dark:text-zinc-300"
                  ]}
                >
                  <span>
                    Closing liability {format_money(
                      @journey.close.refs["currency"],
                      @journey.close.refs["closing_minor"]
                    )}
                  </span>
                  <span :if={@journey.close.refs["external_voucher_number"]}>
                    Voucher
                    <span class={["font-mono font-semibold"]}>
                      {@journey.close.refs["external_voucher_number"]}
                    </span>
                  </span>
                  <span :if={@journey.close.refs["report_sha256"]}>
                    Report
                    <span
                      class={["font-mono font-semibold"]}
                      title={@journey.close.refs["report_sha256"]}
                    >
                      {String.slice(@journey.close.refs["report_sha256"], 0, 12)}
                    </span>
                  </span>
                </div>

                <div class={["mt-3"]}>
                  <.close_action
                    state={@journey.close.state}
                    team_id={@team.id}
                    close_id={@journey.close.refs["close_id"]}
                  />
                </div>
              <% end %>
            </.journey_phase>
          </ol>
        </section>

        <aside class={[
          "flex items-start gap-4 rounded-2xl border border-zinc-200 bg-zinc-50 p-5 dark:border-zinc-800 dark:bg-zinc-900/50"
        ]}>
          <.icon name="hero-information-circle" class={["mt-0.5 size-5 shrink-0 text-zinc-500"]} />
          <p class={["text-xs leading-5 text-zinc-600 dark:text-zinc-300"]}>
            Reset archives this generation and removes your access to its team; it never deletes a
            booked document, ledger movement, close, operation, or evidence file.
          </p>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :number, :string, required: true
  attr :title, :string, required: true
  attr :done, :boolean, required: true
  attr :status, :string, required: true
  attr :status_tone, :atom, required: true
  slot :inner_block, required: true

  defp journey_phase(assigns) do
    ~H"""
    <li
      id={@id}
      class={[
        "relative flex gap-4 rounded-2xl border bg-white p-5 dark:bg-zinc-950",
        if(@done,
          do: "border-emerald-200 shadow-sm dark:border-emerald-900",
          else: "border-zinc-200 dark:border-zinc-800"
        )
      ]}
    >
      <span
        :if={@done}
        class={[
          "relative z-10 flex size-11 shrink-0 items-center justify-center rounded-full bg-emerald-700 text-white ring-4 ring-white dark:bg-emerald-500 dark:text-emerald-950 dark:ring-zinc-950"
        ]}
      >
        <.icon name="hero-check" class="size-5" />
      </span>
      <span
        :if={!@done}
        class={[
          "relative z-10 flex size-11 shrink-0 items-center justify-center rounded-full border font-mono text-xs font-semibold ring-4 ring-white dark:ring-zinc-950",
          if(@status_tone == :muted,
            do:
              "border-zinc-300 bg-zinc-50 text-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
            else:
              "border-emerald-300 bg-emerald-50 text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300"
          )
        ]}
      >
        {@number}
      </span>
      <div class={["min-w-0 flex-1"]}>
        <div class={["flex flex-wrap items-center justify-between gap-2"]}>
          <h3 class={["font-semibold text-zinc-950 dark:text-zinc-50"]}>{@title}</h3>
          <span class={[
            "text-xs font-semibold",
            status_tone_class(@status_tone)
          ]}>
            {@status}
          </span>
        </div>
        {render_slot(@inner_block)}
      </div>
    </li>
    """
  end

  attr :reached, :boolean, required: true
  attr :active, :boolean, required: true
  attr :label, :string, required: true

  defp milestone(assigns) do
    ~H"""
    <li class={["flex items-center gap-2 text-xs"]}>
      <.icon
        :if={@reached}
        name="hero-check-circle-solid"
        class={["size-4 shrink-0 text-emerald-600 dark:text-emerald-400"]}
      />
      <span
        :if={!@reached}
        class={[
          "flex size-4 shrink-0 items-center justify-center",
          @active && "text-emerald-600 dark:text-emerald-400"
        ]}
      >
        <span class={[
          "size-2 rounded-full",
          if(@active,
            do: "bg-emerald-500 animate-pulse",
            else: "border border-zinc-300 dark:border-zinc-700"
          )
        ]} />
      </span>
      <span class={[
        if(@reached,
          do: "text-zinc-700 dark:text-zinc-200",
          else: "text-zinc-500 dark:text-zinc-400"
        )
      ]}>
        {@label}
      </span>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :label, :string, required: true

  defp artifact_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={[
        "inline-flex items-center gap-1.5 text-sm font-semibold text-emerald-700 transition hover:text-emerald-900 dark:text-emerald-400 dark:hover:text-emerald-300"
      ]}
    >
      {@label}
      <.icon name="hero-arrow-right" class="size-3.5" />
    </.link>
    """
  end

  attr :state, :atom, required: true
  attr :team_id, :string, required: true
  attr :subscription_id, :string, default: nil
  attr :intent_id, :string, default: nil

  defp invoice_action(%{state: :not_started} = assigns) do
    ~H"""
    <.artifact_link
      id="demo-invoice-action"
      navigate={~p"/teams/#{@team_id}/subscriptions/#{@subscription_id}"}
      label="Preview and freeze the first year on the subscription"
    />
    """
  end

  defp invoice_action(%{state: state} = assigns)
       when state in [:frozen, :erp_draft, :approved, :erp_booked] do
    assigns = assign(assigns, :label, invoice_action_label(state))

    ~H"""
    <.artifact_link
      id="demo-invoice-action"
      navigate={~p"/teams/#{@team_id}/invoices/#{@intent_id}"}
      label={@label}
    />
    """
  end

  defp invoice_action(%{state: :sync_error} = assigns) do
    ~H"""
    <.artifact_link
      id="demo-invoice-action"
      navigate={~p"/teams/#{@team_id}/operations"}
      label="Open operations to inspect and retry the failure"
    />
    """
  end

  defp invoice_action(assigns), do: ~H""

  defp invoice_action_label(:frozen), do: "Create the ERP draft from the invoice"
  defp invoice_action_label(:erp_draft), do: "Approve the reconciled draft on the invoice"
  defp invoice_action_label(:approved), do: "Book the invoice"
  defp invoice_action_label(:erp_booked), do: "Inspect the invoice evidence"

  attr :state, :atom, required: true
  attr :team_id, :string, required: true
  attr :close_id, :string, default: nil

  defp close_action(%{state: :not_started} = assigns) do
    ~H"""
    <.artifact_link
      id="demo-close-action"
      navigate={~p"/teams/#{@team_id}/credit-closes"}
      label="Open credit closes and freeze the month"
    />
    """
  end

  defp close_action(%{close_id: close_id} = assigns) when is_binary(close_id) do
    assigns = assign(assigns, :label, close_action_label(assigns.state))

    ~H"""
    <.artifact_link
      id="demo-close-action"
      navigate={~p"/teams/#{@team_id}/credit-closes/#{@close_id}"}
      label={@label}
    />
    """
  end

  defp close_action(assigns), do: ~H""

  defp close_action_label(:generating), do: "Follow the close as it freezes"
  defp close_action_label(:generation_failed), do: "Inspect and retry the close calculation"
  defp close_action_label(:ready), do: "Review and approve the frozen report"
  defp close_action_label(:approved), do: "Post the aggregate voucher"
  defp close_action_label(:posting), do: "Follow the durable posting"
  defp close_action_label(:mismatch), do: "Investigate the reconciliation mismatch"
  defp close_action_label(:reconciled), do: "Accept and close the period"
  defp close_action_label(:closed), do: "Inspect the close evidence"
  defp close_action_label(_state), do: "Open the close"

  @impl true
  def mount(_params, _session, socket) do
    case Demo.workspace_for_scope(socket.assigns.scope) do
      {:ok, bundle} ->
        {:ok, journey} = Scenario.observe(bundle)

        {:ok,
         socket
         |> assign(
           page_title: "Northstar Studio · Guided workspace",
           workspace: bundle.workspace,
           connection: bundle.connection,
           journey: journey
         )
         |> maybe_schedule_refresh()}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "That team is not a guided Revryn workspace.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("build_commercial", _params, socket) do
    with {:ok, bundle} <- Demo.workspace_for_scope(socket.assigns.scope),
         {:ok, _refs} <- Scenario.build_commercial_model(bundle),
         {:ok, journey} <- Scenario.observe(bundle) do
      {:noreply,
       socket
       |> assign(journey: journey)
       |> put_flash(
         :info,
         "The commercial model is ready — every artifact was created through the ordinary catalog and contract commands."
       )}
    else
      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The commercial model could not be created. Nothing partial was committed — try again."
         )}
    end
  end

  def handle_event("grant_credit", _params, socket) do
    with {:ok, bundle} <- Demo.workspace_for_scope(socket.assigns.scope),
         {:ok, _refs} <- Scenario.record_customer_credit(bundle),
         {:ok, journey} <- Scenario.observe(bundle) do
      {:noreply,
       socket
       |> assign(journey: journey)
       |> put_flash(
         :info,
         "The goodwill credit is recorded as an individual movement in the customer-credit subledger."
       )}
    else
      {:error, :locked} ->
        {:noreply,
         put_flash(socket, :error, "The credit movement unlocks after the invoice is booked.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The credit movement could not be recorded. Nothing partial was committed — try again."
         )}
    end
  end

  def handle_event("inject_failure", params, socket) do
    # Whitelist-find, never String.to_atom/1 on user input.
    kind =
      Enum.find(
        [:validation, :transient, :authorization, :terminal],
        :validation,
        &(Atom.to_string(&1) == params["kind"])
      )

    case Demo.simulate_provider_failure(socket.assigns.scope, kind) do
      :ok ->
        {:noreply, put_flash(socket, :info, drill_armed_message(kind))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The simulated outage could not be armed.")}
    end
  end

  def handle_event("reset_demo", _params, socket) do
    case Demo.reset_workspace(socket.assigns.current_user) do
      {:ok, bundle} ->
        {:noreply,
         socket
         |> put_flash(:info, "A clean demo generation is ready. Prior evidence was retained.")
         |> push_navigate(to: ~p"/teams/#{bundle.team.id}/demo")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The workspace could not be reset safely. Nothing was deleted."
         )}
    end
  end

  @impl true
  def handle_info(:refresh_journey, socket) do
    case Demo.workspace_for_scope(socket.assigns.scope) do
      {:ok, bundle} ->
        {:ok, journey} = Scenario.observe(bundle)

        {:noreply,
         socket
         |> assign(journey: journey)
         |> maybe_schedule_refresh()}

      {:error, _reason} ->
        {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  defp maybe_schedule_refresh(socket) do
    journey = socket.assigns.journey

    if connected?(socket) and
         (journey.invoice.state in @pending_states or
            journey.close.state in [:generating, :posting]) do
      Process.send_after(self(), :refresh_journey, @refresh_interval)
    end

    socket
  end

  defp connection_status("active"), do: "Passed"
  defp connection_status(_status), do: "Needs attention"

  defp commercial_status(:complete), do: "Ready"
  defp commercial_status(:partial), do: "Resume"
  defp commercial_status(_state), do: "Next step"

  defp invoice_status(:locked), do: "Upcoming"
  defp invoice_status(:not_started), do: "Next step"
  defp invoice_status(:frozen), do: "Next step"
  defp invoice_status(:sync_pending), do: "Working…"
  defp invoice_status(:erp_draft), do: "Next step"
  defp invoice_status(:approved), do: "Next step"
  defp invoice_status(:booking_pending), do: "Working…"
  defp invoice_status(:erp_booked), do: "Ready"
  defp invoice_status(:sync_error), do: "Needs attention"

  defp invoice_status_tone(:locked), do: :muted
  defp invoice_status_tone(:erp_booked), do: :done
  defp invoice_status_tone(:sync_error), do: :alert
  defp invoice_status_tone(_state), do: :next

  defp credit_status(:locked), do: "Upcoming"
  defp credit_status(:complete), do: "Ready"
  defp credit_status(_state), do: "Next step"

  defp credit_status_tone(:locked), do: :muted
  defp credit_status_tone(:complete), do: :done
  defp credit_status_tone(_state), do: :next

  defp close_status(:locked), do: "Upcoming"
  defp close_status(:closed), do: "Ready"
  defp close_status(:generating), do: "Working…"
  defp close_status(:posting), do: "Working…"
  defp close_status(:generation_failed), do: "Needs attention"
  defp close_status(:mismatch), do: "Needs attention"
  defp close_status(_state), do: "Next step"

  defp close_status_tone(:locked), do: :muted
  defp close_status_tone(:closed), do: :done
  defp close_status_tone(:generation_failed), do: :alert
  defp close_status_tone(:mismatch), do: :alert
  defp close_status_tone(_state), do: :next

  defp close_rank(:ready), do: 1
  defp close_rank(:approved), do: 2
  defp close_rank(:posting), do: 2
  defp close_rank(:mismatch), do: 2
  defp close_rank(:reconciled), do: 3
  defp close_rank(:closed), do: 4
  defp close_rank(_state), do: 0

  defp close_body(:not_started),
    do:
      "One close per currency and month bridges every individual subledger movement to a single aggregate liability voucher. Freeze the month of the goodwill credit on the credit-closes page."

  defp close_body(:generating),
    do: "Revryn is freezing the ledger snapshot and rendering the immutable report evidence."

  defp close_body(:generation_failed),
    do: "The close calculation failed and retained its error evidence. Retry from the close page."

  defp close_body(:ready),
    do:
      "The close is frozen: opening → closing, every movement, and the JSON/CSV/PDF/manifest evidence carry one exact report hash awaiting approval."

  defp close_body(:approved),
    do:
      "The exact report hash is approved. Posting creates one durable operation that searches before it creates — no duplicate voucher is possible."

  defp close_body(:posting),
    do:
      "The aggregate voucher is being posted, the report attached, and the authoritative copy read back. This page updates as the operation completes."

  defp close_body(:mismatch),
    do:
      "The provider's authoritative document differs from the approved report. The mismatch evidence is retained; remediate from the operations inbox."

  defp close_body(:reconciled),
    do:
      "Voucher and attachment match the approved report exactly. Accepting the period makes this bridge the authoritative history."

  defp close_body(:closed),
    do:
      "The period is closed: one aggregate voucher in the general ledger, every individual movement still traceable in the subledger, and the attached report binds them together."

  defp close_body(_state), do: "Open the close to continue."

  defp status_tone_class(:done), do: "text-emerald-700 dark:text-emerald-400"
  defp status_tone_class(:next), do: "text-emerald-700 dark:text-emerald-400"
  defp status_tone_class(:alert), do: "text-amber-700 dark:text-amber-400"
  defp status_tone_class(:muted), do: "text-zinc-400"

  defp invoice_rank(:not_started), do: 0
  defp invoice_rank(:frozen), do: 1
  defp invoice_rank(:sync_pending), do: 1
  defp invoice_rank(:sync_error), do: 1
  defp invoice_rank(:erp_draft), do: 2
  defp invoice_rank(:approved), do: 3
  defp invoice_rank(:booking_pending), do: 3
  defp invoice_rank(:erp_booked), do: 4
  defp invoice_rank(_state), do: 0

  defp invoice_body(:not_started),
    do:
      "Preview the exact 12-month service period on the subscription, then freeze it into an immutable intent with a canonical hash."

  defp invoice_body(:frozen),
    do:
      "The intent is frozen and immutable. Continue on the invoice to create the provider draft through a durable, idempotent operation."

  defp invoice_body(:sync_pending),
    do:
      "Revryn is creating the provider draft and reconciling the read-back copy. This page updates as the durable operation completes."

  defp invoice_body(:erp_draft),
    do:
      "The provider draft was reconciled against the frozen intent — line for line, including accrual dates. Approve it to allow booking."

  defp invoice_body(:approved),
    do: "The reconciled draft is approved. Book it to produce the immutable provider document."

  defp invoice_body(:booking_pending),
    do:
      "Revryn is booking the draft and reconciling the booked document. This page updates as the durable operation completes."

  defp invoice_body(:erp_booked),
    do:
      "The booked document was read back from the provider and reconciled, accrual dates intact. The evidence below is the authoritative proof."

  defp invoice_body(:sync_error),
    do:
      "The provider rejected the last operation. Nothing was lost — the durable operation retains the error and can be retried after remediation."

  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%-d %B %Y")

  defp drill_armed_message(:transient),
    do:
      "The provider will fail the next draft creation once with a transient outage. Create the ERP draft and watch the retry policy heal it automatically — no clicks needed."

  defp drill_armed_message(:authorization),
    do:
      "The provider will reject the next draft creation once as an authorization failure. Create the ERP draft, then resolve it the operator way: revalidate the connection under Settings and requeue from operations."

  defp drill_armed_message(:terminal),
    do:
      "The provider will reject the next draft creation once with a non-retryable defect. Create the ERP draft and see how the inbox distinguishes it and hands you a support bundle."

  defp drill_armed_message(_kind),
    do:
      "The provider will reject the next draft creation once. Create the ERP draft to watch the failure land safely — then retry it from operations."
end
