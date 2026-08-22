defmodule BillingCore.Notifications.DeliveryWorker do
  @moduledoc """
  Durable transactional-mail delivery (BC-US-147): bounded retries against
  the configured SMTP relay, unique per logical message so duplicate
  enqueues never emit duplicate mail. Errors are logged without message
  content or secrets.
  """

  use Oban.Worker,
    queue: :email,
    max_attempts: 8,
    unique: [
      fields: [:worker, :args],
      keys: [:template, :event, :to, :dedupe_key],
      period: 86_400
    ]

  require Logger

  alias BillingCore.{Mailer, Notifications}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"template" => template} = args}) do
    email = Notifications.build!(template, args)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        :telemetry.execute(
          [:billing_core, :mail, :delivered],
          %{count: 1},
          %{template: template}
        )

        :ok

      {:error, reason} ->
        # Never log the message or recipient list — class of failure only.
        Logger.warning("mail delivery failed template=#{template} reason=#{redact(reason)}")

        :telemetry.execute(
          [:billing_core, :mail, :delivery_failed],
          %{count: 1},
          %{template: template}
        )

        {:error, :delivery_failed}
    end
  end

  defp redact(reason) when is_atom(reason), do: reason

  defp redact({kind, _detail}) when is_atom(kind), do: kind

  defp redact(_reason), do: :unclassified
end
