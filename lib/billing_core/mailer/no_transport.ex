defmodule BillingCore.Mailer.NoTransport do
  @moduledoc """
  The deliberate mail adapter for deployments without an SMTP relay.

  `config/runtime.exs` selects it in production when `SMTP_HOST` is unset.
  Every delivery returns `{:error, :no_mail_transport}` so callers degrade
  honestly — invitations fall back to their copyable link, notification
  jobs record a delivery failure — instead of crashing into the default
  `Swoosh.Adapters.Local` adapter, whose storage process is disabled in
  releases (`config :swoosh, local: false`).
  """

  use Swoosh.Adapter

  @impl true
  def deliver(%Swoosh.Email{}, _config), do: {:error, :no_mail_transport}

  @impl true
  def deliver_many(emails, _config) when is_list(emails), do: {:error, :no_mail_transport}
end
