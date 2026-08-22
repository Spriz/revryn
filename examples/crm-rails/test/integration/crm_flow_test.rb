require "test_helper"

class CrmFlowTest < ActionDispatch::IntegrationTest
  setup do
    post "/register", params: { email: "lene@example.com", password: "sikkerhed123" }
    post "/organizations", params: { name: "Nordlys" }
    @organization = Organization.find_by!(name: "Nordlys")
    @slug = @organization.slug
  end

  test "companies, contacts, notes, and audit history" do
    post "/orgs/#{@slug}/companies", params: { name: "Fjeldmark ApS", city: "Aarhus" }
    company = @organization.companies.find_by!(name: "Fjeldmark ApS")

    post "/orgs/#{@slug}/contacts",
         params: { full_name: "Bo Berg", email: "bo@fjeldmark.dk", company_id: company.id }
    contact = @organization.contacts.find_by!(email: "bo@fjeldmark.dk")
    assert_equal company, contact.company

    post "/orgs/#{@slug}/notes",
         params: { notable_type: "Contact", notable_id: contact.id, body: "Mødt på messen" }
    assert_equal 1, contact.notes.count

    verbs = @organization.activities.pluck(:verb)
    assert_includes verbs, "company.created"
    assert_includes verbs, "contact.created"
    assert_includes verbs, "note.added"
  end

  test "CSV export and idempotent import round-trip" do
    post "/orgs/#{@slug}/contacts", params: { full_name: "Eva Dam", email: "eva@example.com" }

    get "/orgs/#{@slug}/contacts.csv"
    assert_response :success
    csv = response.body
    assert_match "eva@example.com", csv

    file = Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "contacts.csv")
    post "/orgs/#{@slug}/contacts/import", params: { file: file }
    post "/orgs/#{@slug}/contacts/import", params: { file: Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "contacts.csv") }

    assert_equal 1, @organization.contacts.where(email: "eva@example.com").count
  end

  test "deals move through the pipeline and settle with integer amounts" do
    pipeline = @organization.pipelines.first
    lead = pipeline.stages.find_by!(name: "Lead")
    proposal = pipeline.stages.find_by!(name: "Proposal")

    post "/orgs/#{@slug}/deals",
         params: { stage_id: lead.id, title: "Website relaunch", amount_ore: 1_250_000 }
    deal = @organization.deals.find_by!(title: "Website relaunch")
    assert_equal 1_250_000, deal.amount_ore

    post "/orgs/#{@slug}/deals/#{deal.id}/move", params: { stage_id: proposal.id }
    assert_equal proposal, deal.reload.stage

    post "/orgs/#{@slug}/deals/#{deal.id}/settle", params: { status: "won" }
    assert_equal "won", deal.reload.status

    summaries = @organization.activities.pluck(:summary)
    assert summaries.any? { |summary| summary.include?("from Lead to Proposal") }
  end

  test "search spans companies contacts and deals" do
    post "/orgs/#{@slug}/companies", params: { name: "Kystvej Byg" }
    post "/orgs/#{@slug}/contacts", params: { full_name: "Kysten Kim" }
    pipeline = @organization.pipelines.first
    post "/orgs/#{@slug}/deals",
         params: { stage_id: pipeline.stages.first.id, title: "Kystvej tilbygning" }

    get "/orgs/#{@slug}/search", params: { q: "Kyst" }
    assert_response :success
    assert_match "Kystvej Byg", response.body
    assert_match "Kysten Kim", response.body
    assert_match "Kystvej tilbygning", response.body
  end
end
