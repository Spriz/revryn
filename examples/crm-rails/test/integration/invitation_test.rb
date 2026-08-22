require "test_helper"

class InvitationTest < ActionDispatch::IntegrationTest
  setup do
    post "/register", params: { email: "ejer@example.com", password: "sikkerhed123" }
    post "/organizations", params: { name: "Havblik" }
    @organization = Organization.find_by!(name: "Havblik")
  end

  test "invitation is email-bound and single-use" do
    invitation = @organization.invitations.create!(email: "gaest@example.com")

    wrong = User.create!(email: "forkert@example.com", password: "sikkerhed123")
    assert_raises(ArgumentError) { invitation.accept!(wrong) }

    right = User.create!(email: "gaest@example.com", password: "sikkerhed123")
    membership = invitation.accept!(right)
    assert_equal "member", membership.role
    assert_raises(ArgumentError) { invitation.accept!(right) }
  end

  test "accept flow through the browser URLs grants the invited role" do
    post "/orgs/#{@organization.slug}/invitations",
         params: { email: "med@example.com", role: "admin" }
    invitation = @organization.invitations.find_by!(email: "med@example.com")

    delete "/logout"
    post "/register", params: { email: "med@example.com", password: "sikkerhed123" }
    post "/invitations/#{invitation.token}"
    assert_redirected_to "/orgs/#{@organization.slug}"
    assert_equal "admin", @organization.role_of(User.find_by!(email: "med@example.com"))
  end
end
