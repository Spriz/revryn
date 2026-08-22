defmodule BillingCore.Notifications do
  @moduledoc """
  Transactional email over vendor-neutral SMTP (BC-US-147, BC-TASK-087).

  Templates are pure functions building `Swoosh.Email` structs; delivery is
  durable through `BillingCore.Notifications.DeliveryWorker` (bounded Oban
  retries, unique per logical message so duplicate enqueues cannot emit
  duplicate mail). Message bodies may carry action links; job arguments,
  logs, and telemetry never carry secrets — anything sensitive is passed
  point-to-point into the builder, not persisted.

  The transport is configuration only: `Swoosh.Adapters.SMTP` in
  production (any standards-compliant relay), the local mailbox in dev,
  and the test adapter in tests. No provider HTTP API is involved.
  """

  import Swoosh.Email

  alias BillingCore.Identity.User
  alias BillingCore.Notifications.DeliveryWorker

  @security_events %{
    passkey_added: "A new passkey was added to your Revryn account",
    passkey_revoked: "A passkey was removed from your Revryn account",
    recovery_code_used: "A recovery code was used to sign in to Revryn"
  }

  @doc "Known security notification events."
  @spec security_events() :: [atom()]
  def security_events, do: Map.keys(@security_events)

  @doc """
  Durably enqueues a security notification to the user's primary email.
  A missing primary email is a recorded no-op, never a crash. Unique per
  `(event, user, dedupe_key)` — replays of the same logical event (for
  example a retried command) do not duplicate mail.
  """
  @spec notify_security_event(User.t(), atom(), map()) :: :ok
  def notify_security_event(%User{} = user, event, meta \\ %{}) when is_map(meta) do
    case BillingCore.Identity.get_primary_email(user) do
      nil ->
        :ok

      email ->
        %{
          "template" => "security_event",
          "event" => Atom.to_string(event),
          "to" => email,
          "meta" => safe_meta(meta),
          "dedupe_key" => Map.get(meta, :dedupe_key, Ecto.UUID.generate())
        }
        |> DeliveryWorker.new()
        |> Oban.insert!()

        :ok
    end
  end

  @doc "Builds the email for a template; raises on unknown templates."
  @spec build!(String.t(), map()) :: Swoosh.Email.t()
  def build!("security_event", %{"event" => event, "to" => to} = args) do
    subject =
      Map.get(@security_events, safe_event(event), "Security notice for your Revryn account")

    meta = Map.get(args, "meta", %{})

    body = """
    Hej,

    #{subject}.

    When: #{Map.get(meta, "occurred_at", "just now")}
    #{detail_line(meta)}
    If this was you, no action is needed. If you do not recognize this
    activity, review your passkeys and recovery codes under Security in
    Revryn immediately and remove anything you do not recognize.

    — Revryn
    """

    base_email()
    |> to(to)
    |> subject(subject)
    |> text_body(body)
  end

  def build!("invitation", %{"to" => to, "organization_name" => organization, "url" => url}) do
    base_email()
    |> to(to)
    |> subject("You have been invited to #{organization} on Revryn")
    |> text_body("""
    Hej,

    You have been invited to join #{organization} on Revryn.

    Accept the invitation:

        #{url}

    The link expires; if it has, ask the person who invited you to send a
    new one. If you did not expect this invitation you can ignore this
    message.

    — Revryn
    """)
  end

  def build!(template, _args), do: raise(ArgumentError, "unknown mail template #{template}")

  defp base_email do
    mail_config = Application.get_env(:billing_core, :mail, [])

    email = new() |> from(Keyword.get(mail_config, :from, "no-reply@revryn.localhost"))

    case Keyword.get(mail_config, :reply_to) do
      nil -> email
      reply -> reply_to(email, reply)
    end
  end

  # Job arguments are durable: keep only display-safe metadata, never
  # tokens, codes, or credential material.
  defp safe_meta(meta) do
    meta
    |> Map.take([:credential_name, :occurred_at, :ip])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), to_string(value)} end)
  end

  defp detail_line(%{"credential_name" => name}) when name not in [nil, ""],
    do: "Passkey: #{name}\n"

  defp detail_line(_meta), do: ""

  defp safe_event(event) do
    Enum.find(Map.keys(@security_events), &(Atom.to_string(&1) == event))
  end
end
