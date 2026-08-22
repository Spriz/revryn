defmodule BillingCoreWeb.FirstRunLive do
  @moduledoc """
  First-run choice between a synthetic guided workspace and a real ERP setup.

  The demo path invokes `BillingCore.Demo`; it never inserts billing fixtures or
  bypasses the same adapter and authorization boundaries used by live data.
  """

  use BillingCoreWeb, :live_view

  alias BillingCore.Demo

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class={["mx-auto max-w-6xl py-4 sm:py-8"]} id="first-run">
        <div class={["mb-10 max-w-3xl"]}>
          <.link
            navigate={~p"/"}
            id="back-to-workspaces"
            class={[
              "group inline-flex items-center gap-2 text-sm font-medium text-zinc-500 transition hover:text-zinc-950 dark:text-zinc-400 dark:hover:text-zinc-50"
            ]}
          >
            <.icon
              name="hero-arrow-left"
              class={["size-4 transition-transform group-hover:-translate-x-0.5"]}
            /> Workspaces
          </.link>
          <p class={[
            "mt-8 text-xs font-semibold uppercase tracking-[0.22em] text-emerald-700 dark:text-emerald-400"
          ]}>
            Choose your starting point
          </p>
          <h1 class={[
            "mt-3 text-4xl font-semibold tracking-[-0.03em] text-zinc-950 sm:text-5xl dark:text-zinc-50"
          ]}>
            Start with proof, not promises.
          </h1>
          <p class={["mt-5 max-w-2xl text-base leading-7 text-zinc-600 dark:text-zinc-300"]}>
            See Revryn's control trail with isolated sample books, or prepare a workspace for your
            own e-conomic agreement. The two paths never share provider state or financial records.
          </p>
        </div>

        <div class={["grid gap-5 lg:grid-cols-2"]}>
          <article
            id="demo-erp-path"
            class={[
              "relative overflow-hidden rounded-3xl border border-emerald-200 bg-white p-7 shadow-[0_24px_70px_-45px_rgba(5,150,105,0.65)] sm:p-9 dark:border-emerald-900 dark:bg-zinc-950"
            ]}
          >
            <div class={[
              "absolute right-0 top-0 size-40 translate-x-16 -translate-y-16 rounded-full border-[28px] border-emerald-100/70 dark:border-emerald-950"
            ]} />
            <div class="relative">
              <div class={["flex items-center justify-between gap-4"]}>
                <span class={[
                  "flex size-12 items-center justify-center rounded-2xl bg-emerald-700 text-white dark:bg-emerald-500 dark:text-emerald-950"
                ]}>
                  <.icon name="hero-beaker" class="size-6" />
                </span>
                <span class={[
                  "rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1 text-xs font-semibold text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                ]}>
                  Synthetic & isolated
                </span>
              </div>

              <h2 class={[
                "mt-7 text-2xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50"
              ]}>
                Walk through Northstar Studio
              </h2>
              <p class={["mt-3 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                Follow a prepaid annual subscription from calculation to booked invoice, customer
                credit, monthly liability close, attached report, and authoritative ERP read-back.
              </p>

              <ol
                class={["mt-7 space-y-3 text-sm text-zinc-700 dark:text-zinc-200"]}
                id="demo-proof-points"
              >
                <li class={["flex gap-3"]}>
                  <.icon
                    name="hero-check-circle"
                    class={["mt-0.5 size-5 shrink-0 text-emerald-700 dark:text-emerald-400"]}
                  /> Real domain commands and durable operations
                </li>
                <li class={["flex gap-3"]}>
                  <.icon
                    name="hero-check-circle"
                    class={["mt-0.5 size-5 shrink-0 text-emerald-700 dark:text-emerald-400"]}
                  /> A private mock ERP with reconciled read-back
                </li>
                <li class={["flex gap-3"]}>
                  <.icon
                    name="hero-check-circle"
                    class={["mt-0.5 size-5 shrink-0 text-emerald-700 dark:text-emerald-400"]}
                  /> Deterministic resume and non-destructive reset
                </li>
              </ol>

              <button
                :if={!@active_demo}
                type="button"
                id="start-demo-workspace"
                phx-click="start_demo"
                phx-disable-with="Preparing Northstar Studio…"
                class={[
                  "mt-8 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-emerald-700 px-5 text-sm font-semibold text-white shadow-sm transition hover:-translate-y-0.5 hover:bg-emerald-800 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-700 disabled:cursor-wait disabled:opacity-70 motion-reduce:transform-none dark:bg-emerald-500 dark:text-emerald-950 dark:hover:bg-emerald-400"
                ]}
              >
                Prepare my guided workspace <.icon name="hero-arrow-right" class="size-4" />
              </button>

              <.link
                :if={@active_demo}
                id="resume-demo-workspace"
                navigate={~p"/teams/#{@active_demo.team.id}/demo"}
                class={[
                  "mt-8 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-emerald-700 px-5 text-sm font-semibold text-white shadow-sm transition hover:-translate-y-0.5 hover:bg-emerald-800 hover:shadow-md focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-700 motion-reduce:transform-none dark:bg-emerald-500 dark:text-emerald-950 dark:hover:bg-emerald-400"
                ]}
              >
                Resume Northstar Studio <.icon name="hero-arrow-right" class="size-4" />
              </.link>

              <p class={["mt-3 text-center text-xs leading-5 text-zinc-500 dark:text-zinc-400"]}>
                No live credentials. Every sample record is clearly marked.
              </p>
            </div>
          </article>

          <article
            id="real-erp-path"
            class={[
              "rounded-3xl border border-zinc-200 bg-zinc-50 p-7 sm:p-9 dark:border-zinc-800 dark:bg-zinc-900/50"
            ]}
          >
            <span class={[
              "flex size-12 items-center justify-center rounded-2xl border border-zinc-200 bg-white text-zinc-700 shadow-sm dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200"
            ]}>
              <.icon name="hero-building-office-2" class="size-6" />
            </span>
            <h2 class={["mt-7 text-2xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50"]}>
              Connect your company books
            </h2>
            <p class={["mt-3 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
              Use this route when your team structure, e-conomic agreement, journal, accounts, and
              finance approval policy are ready for validation.
            </p>

            <div class={[
              "mt-7 rounded-2xl border border-zinc-200 bg-white p-5 dark:border-zinc-700 dark:bg-zinc-900"
            ]}>
              <p class={["text-sm font-semibold text-zinc-950 dark:text-zinc-50"]}>
                What you will need
              </p>
              <ul class={["mt-4 space-y-3 text-sm leading-6 text-zinc-600 dark:text-zinc-300"]}>
                <li class={["flex gap-3"]}>
                  <span class={["font-mono text-xs font-semibold text-zinc-400"]}>01</span>
                  An organization owner to create your team workspace
                </li>
                <li class={["flex gap-3"]}>
                  <span class={["font-mono text-xs font-semibold text-zinc-400"]}>02</span>
                  An e-conomic app secret and agreement grant in your secret store
                </li>
                <li class={["flex gap-3"]}>
                  <span class={["font-mono text-xs font-semibold text-zinc-400"]}>03</span>
                  Accountant-approved mappings before the first write
                </li>
              </ul>
            </div>

            <div class={[
              "mt-7 rounded-2xl border border-zinc-200 bg-white p-5 dark:border-zinc-700 dark:bg-zinc-900"
            ]}>
              <p class={["text-sm font-semibold text-zinc-950 dark:text-zinc-50"]}>
                Create your workspace
              </p>
              <p class={["mt-1 text-xs leading-5 text-zinc-500 dark:text-zinc-400"]}>
                One organization with its first team; you become its owner and team admin. The
                e-conomic connection is configured afterwards under Settings.
              </p>
              <.form
                for={@workspace_form}
                id="create-workspace-form"
                phx-submit="create_workspace"
                class={["mt-4 space-y-3"]}
              >
                <.input
                  field={@workspace_form[:name]}
                  type="text"
                  label="Organization name"
                  placeholder="e.g. Fjordlys Software ApS"
                  required
                />
                <div class={["grid gap-3 sm:grid-cols-2"]}>
                  <.input
                    field={@workspace_form[:team_name]}
                    type="text"
                    label="First team"
                    placeholder="Finance"
                  />
                  <.input
                    field={@workspace_form[:base_currency]}
                    type="select"
                    label="Base currency"
                    options={["DKK", "EUR", "SEK", "NOK", "USD", "GBP"]}
                  />
                </div>
                <.input
                  field={@workspace_form[:legal_name]}
                  type="text"
                  label="Legal name (invoices and vouchers)"
                />
                <button
                  type="submit"
                  id="create-workspace"
                  phx-disable-with="Creating your workspace…"
                  class={[
                    "inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-xl border border-zinc-900 bg-zinc-900 px-5 text-sm font-semibold text-white transition hover:bg-zinc-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-zinc-900 disabled:cursor-wait disabled:opacity-70 dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white"
                  ]}
                >
                  Create workspace <.icon name="hero-arrow-right" class="size-4" />
                </button>
              </.form>
            </div>

            <p class={[
              "mt-7 flex items-start gap-3 text-xs leading-5 text-zinc-500 dark:text-zinc-400"
            ]}>
              <.icon name="hero-lock-closed" class={["mt-0.5 size-4 shrink-0"]} />
              Credentials are resolved from a secret reference and are never stored in Revryn's database.
            </p>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    active_demo =
      case Demo.active_workspace(socket.assigns.current_user) do
        {:ok, bundle} -> bundle
        {:error, _reason} -> nil
      end

    {:ok,
     assign(socket,
       page_title: "Start with Revryn",
       active_demo: active_demo,
       workspace_form:
         to_form(
           %{
             "name" => "",
             "team_name" => "Finance",
             "base_currency" => "DKK",
             "legal_name" => ""
           },
           as: "workspace"
         )
     )}
  end

  @impl true
  def handle_event("create_workspace", %{"workspace" => params}, socket) do
    attrs = %{
      name: params["name"],
      team_name: presence(params["team_name"]) || "Finance",
      base_currency: presence(params["base_currency"]) || "DKK",
      legal_name: presence(params["legal_name"]) || params["name"]
    }

    case BillingCore.Orgs.create_organization(attrs, socket.assigns.current_user) do
      {:ok, created} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Your workspace is ready. Configure the e-conomic connection under Settings when your credentials are approved."
         )
         |> push_navigate(to: ~p"/teams/#{created.team.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, BillingCoreWeb.LiveHelpers.error_message(changeset))}
    end
  end

  def handle_event("start_demo", _params, socket) do
    case Demo.start_workspace(socket.assigns.current_user) do
      {:ok, bundle} ->
        {:noreply, push_navigate(socket, to: ~p"/teams/#{bundle.team.id}/demo")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, demo_error(reason))}
    end
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp demo_error(:demo_disabled),
    do: "Guided workspaces are disabled in this deployment. Ask an administrator to enable them."

  defp demo_error(:unauthorized), do: "Your account cannot create a guided workspace."
  defp demo_error(_reason), do: "Revryn could not prepare the guided workspace. Please try again."
end
