defmodule BillingCoreWeb.CreditCloses.ReportController do
  @moduledoc """
  Authenticated, team-scoped download of one immutable close evidence file
  (BC-US-163 report access). Resolves the same `BillingCore.Scope` as the
  LiveView surfaces and serves the exact stored bytes — the SHA-256 in the
  close manifest can be verified against the download.
  """

  use BillingCoreWeb, :controller

  alias BillingCore.{Orgs, Repo}
  alias BillingCore.Credits.Close.Evidence
  alias BillingCore.Credits.CloseWorkflow
  alias BillingCore.Orgs.Team

  def download(conn, %{"team_id" => team_id, "id" => close_id, "evidence_type" => type_param}) do
    user = conn.assigns.current_user

    with {:ok, team_uuid} <- Ecto.UUID.cast(team_id),
         %Team{} = team <- Repo.get(Team, team_uuid),
         {:ok, scope} <- Orgs.resolve_scope(user, team.organization_id, team.id),
         {:ok, evidence_type} <- cast_evidence_type(type_param),
         {:ok, close_uuid} <- Ecto.UUID.cast(close_id),
         {:ok, evidence} <- CloseWorkflow.report(scope, close_uuid, evidence_type) do
      send_download(conn, {:binary, evidence.bytes},
        filename: filename(close_uuid, evidence_type, evidence.content_type),
        content_type: evidence.content_type
      )
    else
      _failure ->
        conn
        |> put_flash(:error, "That report is not available.")
        |> redirect(to: "/")
        |> halt()
    end
  end

  # Never `String.to_atom/1` on request input — resolve against the fixed
  # evidence-type list.
  defp cast_evidence_type(param) when is_binary(param) do
    case Enum.find(Evidence.evidence_types(), &(Atom.to_string(&1) == param)) do
      nil -> {:error, :unknown_evidence_type}
      evidence_type -> {:ok, evidence_type}
    end
  end

  defp filename(close_id, evidence_type, content_type) do
    "credit-close-#{String.slice(close_id, 0, 8)}-#{evidence_type}.#{extension(content_type)}"
  end

  defp extension("application/json"), do: "json"
  defp extension("text/csv"), do: "csv"
  defp extension("application/pdf"), do: "pdf"
  defp extension("text/plain"), do: "txt"
  defp extension(_content_type), do: "bin"
end
