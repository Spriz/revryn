require "test_helper"

class AuthAndOrgTest < ActionDispatch::IntegrationTest
  def register!(email = "anna@example.com")
    post "/register", params: { email: email, password: "sikkerhed123", full_name: "Anna" }
    User.find_by!(email: email)
  end

  test "register signs in and lands home" do
    register!
    assert_redirected_to "/"
  end

  test "login rejects wrong password" do
    register!
    delete "/logout"
    post "/login", params: { email: "anna@example.com", password: "forkert" }
    assert_response :unprocessable_entity
    assert_match "Wrong email or password", response.body
  end

  test "creating an organization scaffolds pipeline stages and owner role" do
    register!
    post "/organizations", params: { name: "Kystvej Consulting" }
    organization = Organization.find_by!(name: "Kystvej Consulting")
    assert_equal "owner", organization.role_of(User.find_by!(email: "anna@example.com"))
    assert_equal %w[Lead Qualified Proposal Won],
                 organization.pipelines.first.stages.map(&:name)
  end

  test "the last owner cannot be demoted or removed" do
    register!
    post "/organizations", params: { name: "Solo" }
    organization = Organization.find_by!(name: "Solo")
    membership = organization.memberships.first

    patch "/orgs/#{organization.slug}/members/#{membership.id}", params: { role: "member" }
    assert_equal "owner", membership.reload.role

    delete "/orgs/#{organization.slug}/members/#{membership.id}"
    assert_equal "active", membership.reload.status
  end

  test "non-members get 403 on organization pages" do
    register!
    post "/organizations", params: { name: "Privat" }
    organization = Organization.find_by!(name: "Privat")

    delete "/logout"
    register!("fremmed@example.com")
    get "/orgs/#{organization.slug}"
    assert_response :forbidden
    get "/orgs/#{organization.slug}/contacts"
    assert_response :forbidden
  end
end
