# Billing Core-backed seam provider (BC-US-150 final milestone).
#
# The seat line comes LIVE from the platform invoice preview — with the
# fingerprint and lines for traceability; the base plan and add-on remain
# fixture-priced pending a flat-fee plan model upstream (documented in
# docs/reviews/showcase-integrated-certification.md).
module BillingCore
  class Provider
    PREVIEW = <<~GQL
      query($teamId: ID!, $subscriptionId: ID!, $asOf: Date!) {
        invoicePreview(teamId: $teamId, subscriptionId: $subscriptionId, asOf: $asOf) {
          netAmountMinor
          fingerprint
          lines { lineKey description quantity amountMinor }
        }
      }
    GQL

    def initialize(client = Client.new)
      @client = client
    end

    def summarize(organization)
      link = Provisioning.ensure_provisioned(organization, @client)
      preview = @client.execute(PREVIEW, {
        "teamId" => @client.team_id,
        "subscriptionId" => link.subscription_ref,
        "asOf" => Date.today.iso8601
      }).fetch("invoicePreview")

      billable = organization.billable_seats
      months = organization.billing_interval == "annual" ? BillingSeam::ANNUAL_MONTHS_CHARGED : 1
      seat_lines, other_lines = preview["lines"].partition { |line| line["lineKey"].include?(":component:seat:") }
      seats = seat_lines.sum { |line| line["amountMinor"] } * months
      # The flat base is platform-priced too (minimum-commit component);
      # only the optional add-on remains commercial fixture config.
      base = other_lines.sum { |line| line["amountMinor"] } * months
      addon = organization.automation_addon ? BillingSeam::AUTOMATION_ADDON_ORE * months : 0

      summary = BillingSeam::Summary.new(
        interval: organization.billing_interval,
        active_seats: organization.active_seats,
        billable_seats: billable,
        base_ore: base,
        seats_ore: seats,
        addon_ore: addon,
        period_total_ore: base + seats + addon
      )
      summary.define_singleton_method(:preview_lines) { preview["lines"] }
      summary.define_singleton_method(:preview_fingerprint) { preview["fingerprint"] }
      summary
    end
  end
end
