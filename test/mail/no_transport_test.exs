defmodule BillingCore.Mailer.NoTransportTest do
  @moduledoc """
  Batch delivery through the deliberate no-relay adapter must degrade with
  the same honest `{:error, :no_mail_transport}` as single delivery, so
  batch senders (notification digests) record failures instead of crashing.
  `deliver/2` is covered end-to-end by
  `test/mail/mail_transport_degradation_test.exs`.
  """

  use ExUnit.Case, async: true

  alias BillingCore.Mailer.NoTransport

  defp email(subject) do
    Swoosh.Email.new(
      to: {"Recipient", "recipient@example.com"},
      from: {"Billing Core", "billing@example.com"},
      subject: subject,
      text_body: "body"
    )
  end

  test "deliver_many/2 reports the missing transport for a batch" do
    emails = [email("first"), email("second")]

    assert NoTransport.deliver_many(emails, []) == {:error, :no_mail_transport}
  end

  test "deliver_many/2 reports the missing transport even for an empty batch" do
    assert NoTransport.deliver_many([], []) == {:error, :no_mail_transport}
  end

  test "the adapter declares no external runtime dependencies" do
    # The whole point of NoTransport is working in deployments with no mail
    # infrastructure — it must never require optional deps at runtime.
    assert NoTransport.validate_dependency() == :ok
  end
end
