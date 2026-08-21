defmodule BillingCore.ERP.PollWorker do
  @moduledoc """
  Polling fallback and webhook follow-up reads (SPEC §17.12, BC-US-086).

  Fetches the authoritative provider state for a connection's open documents:
  detects external booking (reconciling before any state claim), refreshes
  draft snapshots so human edits are visible as hash drift, and marks
  externally deleted documents `missing`.
  """

  use Oban.Worker, queue: :reconciliation, max_attempts: 5

  import Ecto.Query

  alias BillingCore.{Billing, Outbox, Repo}
  alias BillingCore.Billing.InvoiceIntent
  alias BillingCore.Domain.Canonical
  alias BillingCore.ERP
  alias BillingCore.ERP.{Connection, ErpDocument}
  alias BillingCore.ERP.Sync.Builder
  alias BillingCore.Reconciliation.Comparator

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"erp_connection_id" => connection_id}}) do
    connection = Repo.get!(Connection, connection_id)
    adapter = ERP.adapter_for(connection)
    ctx = ERP.connection_context(connection)

    documents =
      Repo.all(
        from d in ErpDocument,
          where:
            d.erp_connection_id == ^connection.id and
              d.state in ["draft", "syncing"]
      )

    Enum.each(documents, fn doc -> poll_document(adapter, ctx, doc) end)
    :ok
  end

  defp poll_document(adapter, ctx, doc) do
    case adapter.find_document(ctx, doc.external_reference) do
      {:ok, nil} ->
        doc
        |> Ecto.Changeset.change(state: "missing")
        |> Ecto.Changeset.optimistic_lock(:version)
        |> Repo.update!()

        record_result!(doc, "missing", doc.last_external_hash, nil, [])

      {:ok, %{state: :booked} = external} ->
        handle_external_booking(doc, external)

      {:ok, %{state: :draft} = external} ->
        # Refresh the external snapshot so approval-hash drift is detectable.
        doc
        |> Ecto.Changeset.change(
          last_external_snapshot: snapshot(external),
          last_external_hash: external.external_hash
        )
        |> Ecto.Changeset.optimistic_lock(:version)
        |> Repo.update!()

      {:error, _reason} ->
        # Transient poll failures are retried by the next scheduled poll.
        :ok
    end
  end

  defp record_result!(doc, status, expected_hash, external, differences) do
    Repo.insert_all(
      "reconciliation_results",
      [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          team_id: Ecto.UUID.dump!(doc.team_id),
          erp_document_id: Ecto.UUID.dump!(doc.id),
          run_kind: "poll",
          expected_hash: expected_hash,
          actual_hash: external && external.external_hash,
          status: status,
          differences: %{
            "items" =>
              Enum.map(
                differences,
                &%{"severity" => to_string(&1.severity), "field" => to_string(&1.field)}
              )
          },
          ran_at: DateTime.utc_now()
        }
      ],
      prefix: "billing"
    )
  end

  defp handle_external_booking(doc, external) do
    intent =
      Repo.one!(from i in InvoiceIntent, where: i.id == ^doc.invoice_intent_id, preload: [:lines])

    connection = Repo.get!(Connection, doc.erp_connection_id)
    {:ok, canonical} = Builder.build(intent, connection)

    case Comparator.compare(canonical, external) do
      %Comparator.Result{status: :match} ->
        {:ok, _} =
          Repo.transaction(fn ->
            doc
            |> Ecto.Changeset.change(
              state: "booked",
              external_booked_number: external.external_booked_number,
              last_external_snapshot: snapshot(external),
              last_external_hash: external.external_hash,
              last_reconciled_at: DateTime.utc_now()
            )
            |> Ecto.Changeset.optimistic_lock(:version)
            |> Repo.update!()

            case Billing.transition_intent(:system, intent, :externally_booked) do
              {:ok, _} -> :ok
              {:error, {:illegal_state, _}} -> :ok
            end

            Outbox.emit!("erp_document.booked.v1",
              aggregate: {:erp_document, doc.id},
              team_id: doc.team_id,
              payload: %{
                invoice_intent_id: intent.id,
                external_booked_number: external.external_booked_number,
                observed: "externally"
              }
            )

            record_result!(doc, "match", intent.content_hash, external, [])
          end)

        :ok

      %Comparator.Result{status: :mismatch, differences: differences} ->
        {:ok, _} =
          Repo.transaction(fn ->
            doc
            |> Ecto.Changeset.change(
              state: "reconciliation_failed",
              external_booked_number: external.external_booked_number,
              last_external_snapshot: snapshot(external),
              last_external_hash: external.external_hash,
              last_reconciled_at: DateTime.utc_now()
            )
            |> Ecto.Changeset.optimistic_lock(:version)
            |> Repo.update!()

            Outbox.emit!("erp_document.reconciliation_failed.v1",
              aggregate: {:erp_document, doc.id},
              team_id: doc.team_id,
              payload: %{
                invoice_intent_id: intent.id,
                differences: Enum.map(differences, &%{severity: &1.severity, field: &1.field})
              }
            )

            record_result!(doc, "mismatch", intent.content_hash, external, differences)
          end)

        :ok
    end
  end

  defp snapshot(external) do
    external
    |> Map.from_struct()
    |> Map.take([
      :state,
      :external_draft_id,
      :external_booked_number,
      :external_reference,
      :currency
    ])
    |> Canonical.encode!()
    |> Jason.decode!()
  end
end
