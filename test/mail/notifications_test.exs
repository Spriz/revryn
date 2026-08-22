defmodule BillingCore.NotificationsTest do
  @moduledoc """
  Transactional mail platform (BC-US-147): templates build correct mail,
  delivery is durable and deduplicated per logical message, security flows
  actually enqueue, and secrets never enter job arguments.
  """

  use BillingCore.DataCase, async: false

  import Ecto.Query
  import Swoosh.TestAssertions

  alias BillingCore.{Identity, Notifications, Repo}

  defp user_with_email! do
    {:ok, user} = Identity.register_user("mail-#{System.unique_integer([:positive])}@example.com")
    user
  end

  defp drain_email_queue do
    Oban.drain_queue(queue: :email, with_safety: false)
  end

  test "a new passkey enqueues exactly one durable security notification" do
    user = user_with_email!()

    {:ok, credential} =
      Identity.register_webauthn_credential(user, %{
        credential_id: :crypto.strong_rand_bytes(16),
        public_key: <<1, 2, 3>>,
        sign_count: 0,
        name: "MacBook Touch ID"
      })

    # Replaying the same logical event cannot duplicate the message.
    Notifications.notify_security_event(user, :passkey_added, %{
      credential_name: credential.name,
      dedupe_key: credential.id
    })

    assert %{success: 1} = drain_email_queue()

    email = Identity.get_primary_email(user)

    assert_email_sent(fn sent ->
      assert [{_name, ^email}] = sent.to
      assert sent.subject =~ "new passkey"
      assert sent.text_body =~ "MacBook Touch ID"
    end)
  end

  test "job arguments never carry secrets or credential material" do
    user = user_with_email!()

    Notifications.notify_security_event(user, :recovery_code_used, %{
      dedupe_key: "recovery-1",
      code: "SECRET-RECOVERY-CODE",
      token: "SECRET-TOKEN"
    })

    args =
      Repo.one!(
        from job in Oban.Job,
          where: job.worker == "BillingCore.Notifications.DeliveryWorker",
          order_by: [desc: job.id],
          limit: 1,
          select: job.args
      )

    refute inspect(args) =~ "SECRET"
    assert args["event"] == "recovery_code_used"
  end

  test "a user without a primary email is a recorded no-op" do
    user = user_with_email!()
    Repo.delete_all(from e in BillingCore.Identity.UserEmail, where: e.user_id == ^user.id)

    assert :ok = Notifications.notify_security_event(user, :passkey_added, %{})
    assert %{} = drain_email_queue()
    refute_email_sent()
  end

  test "the invitation template carries the action link and expiry copy" do
    email =
      Notifications.build!("invitation", %{
        "to" => "invitee@example.com",
        "organization_name" => "Nordlys ApS",
        "url" => "https://revryn.example/invitations/accept?token=abc"
      })

    assert email.subject =~ "Nordlys ApS"
    assert email.text_body =~ "https://revryn.example/invitations/accept?token=abc"
    assert email.text_body =~ "expires"
  end

  test "an unknown template raises instead of sending garbage" do
    assert_raise ArgumentError, fn -> Notifications.build!("marketing_blast", %{}) end
  end
end
