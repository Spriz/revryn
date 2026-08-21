defmodule BillingCore.Identity.RegistrationTest do
  use BillingCore.DataCase, async: true

  alias BillingCore.Identity
  alias BillingCore.Identity.{User, UserEmail}

  import BillingCore.IdentityFixtures

  describe "register_user/1" do
    test "creates an active user with a primary, unverified email" do
      email = unique_email()

      assert {:ok, %User{} = user} = Identity.register_user(email)
      assert user.status == :active
      refute user.platform_admin

      assert [%UserEmail{} = user_email] = user.emails
      assert user_email.email == email
      assert user_email.primary
      assert user_email.verified_at == nil
    end

    test "email uniqueness is global and case-insensitive" do
      email = unique_email()
      assert {:ok, _user} = Identity.register_user(email)

      assert {:error, :email_taken} = Identity.register_user(email)
      assert {:error, :email_taken} = Identity.register_user(String.upcase(email))

      # no orphan user row leaks from the failed registration
      assert Repo.aggregate(User, :count) == 1
    end

    test "rejects invalid addresses" do
      assert {:error, %Ecto.Changeset{} = changeset} = Identity.register_user("not-an-email")
      assert %{email: [_ | _]} = errors_on(changeset)
      assert Repo.aggregate(User, :count) == 0
    end
  end

  describe "lookup and verification" do
    test "get_user_by_email/1 is case-insensitive" do
      email = unique_email()
      {:ok, user} = Identity.register_user(email)

      assert Identity.get_user_by_email(String.upcase(email)).id == user.id
      assert Identity.get_user_by_email(unique_email()) == nil
    end

    test "get_user!/1 fetches by id" do
      user = user_fixture()
      assert Identity.get_user!(user.id).id == user.id
    end

    test "verify_email/1 stamps verified_at once" do
      email = unique_email()
      {:ok, _user} = Identity.register_user(email)

      assert {:ok, verified} = Identity.verify_email(email)
      assert %DateTime{} = verified.verified_at

      # idempotent — the original timestamp is preserved
      assert {:ok, verified_again} = Identity.verify_email(verified)
      assert verified_again.verified_at == verified.verified_at

      assert {:error, :not_found} = Identity.verify_email(unique_email())
    end
  end
end
