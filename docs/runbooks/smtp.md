# Runbook: transactional email over SMTP

Scope: configuring, verifying, and triaging Revryn's vendor-neutral mail
transport (BC-US-147, BC-TASK-087). Any standards-compliant SMTP relay
works — Mailgun/SendGrid/Resend/Postmark SMTP endpoints, a corporate
relay, or a local capture server — with configuration only; no provider
HTTP API and no application code change.

## Configuration (production release)

| Variable | Meaning | Default |
|----------|---------|---------|
| `SMTP_HOST` | Relay hostname. Mail transport is **disabled** when unset (delivery jobs fail with a clear error rather than silently dropping). | — |
| `SMTP_PORT` | Relay port. | `587` |
| `SMTP_TLS` | `starttls` (587), `ssl` (implicit TLS, 465), or `never` (isolated labs only). Peer verification is always on for TLS modes. | `starttls` |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | Relay credentials; auth is skipped when no username is set. | — |
| `MAIL_FROM` | From address. | `no-reply@$PHX_HOST` |
| `MAIL_REPLY_TO` | Optional reply-to. | — |

Development uses the Swoosh local mailbox (`/dev/mailbox`); tests use the
in-memory test adapter.

## Delivery semantics

Every message goes through the durable `Notifications.DeliveryWorker`
(Oban queue `email`, 8 bounded attempts with backoff). Jobs are unique per
logical message — template, event, recipient, dedupe key — so a retried
command or duplicate enqueue cannot email a person twice. Job arguments
carry only display-safe metadata; tokens, codes, and credential material
never enter durable job state or logs (test-enforced). Telemetry:
`[:billing_core, :mail, :delivered]` / `[:billing_core, :mail,
:delivery_failed]` counters tagged by template; failure logs carry the
failure class only.

Current flows: security notifications (passkey added/removed, recovery
code used) and the invitation template (wired when the invitation surfaces
land).

## Verifying a relay

```sh
SMTP_HOST=smtp.example.com SMTP_USERNAME=... SMTP_PASSWORD=... \
  bin/billing_core rpc '
    BillingCore.Notifications.build!("security_event", %{
      "event" => "passkey_added", "to" => "you@example.com", "meta" => %{}
    }) |> BillingCore.Mailer.deliver() |> IO.inspect()'
```

A `{:ok, _}` confirms transport + auth + TLS. Common failures:
`:econnrefused`/timeouts → host/port/firewall; TLS handshake errors → wrong
`SMTP_TLS` mode for the port, or a relay certificate not covered by the
system CA store; `535` → credentials; `553/554` → unverified `MAIL_FROM`
domain (SPF/DKIM are relay-side concerns).

## Triage

- Nothing arrives, no errors → check the `email` Oban queue and the
  delivered/failed counters in LiveDashboard; jobs stuck in `retryable`
  carry the failure class in their error list.
- Duplicate complaints → verify callers pass a stable `dedupe_key` for the
  logical event (the uniqueness window is 24h).
- Never grep logs for message content — it is not there by design.
