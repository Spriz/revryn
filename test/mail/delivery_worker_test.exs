defmodule BillingCore.MailDeliveryErrorStubAdapter do
  @moduledoc """
  Test stand-in for an SMTP relay refusing mail: returns the `{:error,
  reason}` configured under the mailer's `:error_reason` key so each test
  can exercise a different failure class.
  """

  use Swoosh.Adapter

  @impl true
  def deliver(%Swoosh.Email{}, config), do: {:error, Keyword.fetch!(config, :error_reason)}
end

defmodule BillingCore.Notifications.DeliveryWorkerTest do
  @moduledoc """
  Durable transactional-mail delivery (BC-US-147): success emits mail and
  telemetry, relay failures return a retryable error whose log line carries
  only the failure class (never recipients or message content), and the
  unique-job configuration keeps one logical message from enqueuing twice.
  """

  use BillingCore.DataCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias BillingCore.Notifications.DeliveryWorker

  @invitation_args %{
    "template" => "invitation",
    "to" => "invitee@example.com",
    "organization_name" => "Nordlys ApS",
    "url" => "https://revryn.example/invitations/accept?token=abc",
    "dedupe_key" => "invitation-1"
  }

  setup do
    previous = Application.get_env(:billing_core, BillingCore.Mailer)
    on_exit(fn -> Application.put_env(:billing_core, BillingCore.Mailer, previous) end)

    test_pid = self()
    handler_id = "delivery-worker-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [[:billing_core, :mail, :delivered], [:billing_core, :mail, :delivery_failed]],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp perform!(args), do: DeliveryWorker.perform(%Oban.Job{args: args})

  defp swap_adapter!(error_reason) do
    Application.put_env(:billing_core, BillingCore.Mailer,
      adapter: BillingCore.MailDeliveryErrorStubAdapter,
      error_reason: error_reason
    )
  end

  test "successful delivery sends the built email and emits the delivered metric" do
    assert :ok = perform!(@invitation_args)

    assert_email_sent(fn sent ->
      assert [{_name, "invitee@example.com"}] = sent.to
      assert sent.subject =~ "Nordlys ApS"
      assert sent.text_body =~ "https://revryn.example/invitations/accept?token=abc"
    end)

    assert_receive {:telemetry, [:billing_core, :mail, :delivered], %{count: 1},
                    %{template: "invitation"}}
  end

  test "a relay error returns a retryable failure and emits the failure metric" do
    swap_adapter!(:timeout)

    log =
      capture_log(fn ->
        assert {:error, :delivery_failed} = perform!(@invitation_args)
      end)

    assert log =~ "mail delivery failed template=invitation reason=timeout"

    # The failure log carries the class only — never recipients or content.
    refute log =~ "invitee@example.com"
    refute log =~ "Nordlys"

    assert_receive {:telemetry, [:billing_core, :mail, :delivery_failed], %{count: 1},
                    %{template: "invitation"}}
  end

  test "tuple failure reasons are redacted to their kind" do
    swap_adapter!({:retries_exceeded, {:network_failure, "smtp.internal:587"}})

    log =
      capture_log(fn ->
        assert {:error, :delivery_failed} = perform!(@invitation_args)
      end)

    assert log =~ "reason=retries_exceeded"
    refute log =~ "smtp.internal"
  end

  test "unclassifiable failure reasons never leak provider detail into logs" do
    swap_adapter!("550 5.1.1 mailbox invitee@example.com unavailable")

    log =
      capture_log(fn ->
        assert {:error, :delivery_failed} = perform!(@invitation_args)
      end)

    assert log =~ "reason=unclassified"
    refute log =~ "invitee@example.com"
  end

  test "one logical message never enqueues twice, even when non-key args differ" do
    assert %Oban.Job{conflict?: false} =
             @invitation_args |> DeliveryWorker.new() |> Oban.insert!()

    # Same (template, event, to, dedupe_key) identity with a different URL is
    # still the same logical message.
    assert %Oban.Job{conflict?: true} =
             @invitation_args
             |> Map.put("url", "https://revryn.example/other")
             |> DeliveryWorker.new()
             |> Oban.insert!()

    # A different dedupe key is a new logical message.
    assert %Oban.Job{conflict?: false} =
             @invitation_args
             |> Map.put("dedupe_key", "invitation-2")
             |> DeliveryWorker.new()
             |> Oban.insert!()

    jobs =
      Repo.all(
        from job in Oban.Job,
          where: job.worker == "BillingCore.Notifications.DeliveryWorker"
      )

    assert length(jobs) == 2
  end
end
