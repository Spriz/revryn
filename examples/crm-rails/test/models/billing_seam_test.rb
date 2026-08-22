require "test_helper"
require "billing_seam"

class BillingSeamTest < ActiveSupport::TestCase
  def organization(**attrs)
    Organization.create!({ name: "Seam", slug: "seam-#{SecureRandom.hex(3)}" }.merge(attrs))
  end

  def add_member!(organization, email)
    user = User.create!(email: email, password: "sikkerhed123")
    organization.memberships.create!(user: user)
  end

  test "monthly summary prices base plus per active seat in integer oere" do
    org = organization
    2.times { |n| add_member!(org, "m#{n}@example.com") }

    summary = BillingSeam.provider.summarize(org.reload)
    assert_equal 2, summary.active_seats
    assert_equal BillingSeam::BASE_PLAN_ORE, summary.base_ore
    assert_equal 2 * BillingSeam::PER_SEAT_ORE, summary.seats_ore
    assert_equal 0, summary.addon_ore
    assert_equal summary.base_ore + summary.seats_ore, summary.period_total_ore
  end

  test "annual prepay charges twelve months as ten and the addon follows" do
    org = organization(billing_interval: "annual", automation_addon: true)
    add_member!(org, "aarlig@example.com")

    summary = BillingSeam.provider.summarize(org.reload)
    assert_equal BillingSeam::BASE_PLAN_ORE * 10, summary.base_ore
    assert_equal BillingSeam::PER_SEAT_ORE * 10, summary.seats_ore
    assert_equal BillingSeam::AUTOMATION_ADDON_ORE * 10, summary.addon_ore
  end

  test "seat increases bill immediately, decreases wait for the period rollover" do
    org = organization(seat_decrease_timing: "period_end")
    3.times { |n| add_member!(org, "seat#{n}@example.com") }
    assert_equal 3, org.reload.billable_seats

    org.memberships.last.update!(status: "removed")
    assert_equal 2, org.reload.active_seats
    assert_equal 3, org.billable_seats, "decrease must wait for period end"

    org.update!(committed_seats: org.active_seats) # the rollover action
    assert_equal 2, org.reload.billable_seats

    org.update!(seat_decrease_timing: "immediate")
    org.memberships.active.last.update!(status: "removed")
    assert_equal 1, org.reload.billable_seats, "immediate timing follows live seats"
  end

  test "format_ore renders minor units without floats" do
    assert_equal "12,345.01 DKK", BillingSeam.format_ore(1_234_501)
  end
end
