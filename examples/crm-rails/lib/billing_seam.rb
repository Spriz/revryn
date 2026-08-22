# The application-local billing seam (BC-US-150, INV-030/031).
#
# Every plan/entitlement question goes through BillingSeam.provider and
# nothing else; standalone answers come from the fixtures below, and the
# future Billing Core integration swaps the provider without touching a
# single caller. Amounts are integer oere — never floats.
module BillingSeam
  BASE_PLAN_ORE = 24_900          # per month
  PER_SEAT_ORE = 9_900            # per active seat per month
  AUTOMATION_ADDON_ORE = 14_900   # optional flat add-on per month
  ANNUAL_MONTHS_CHARGED = 10      # annual prepay: 12 months for the price of 10

  Summary = Struct.new(
    :interval, :active_seats, :billable_seats, :base_ore, :seats_ore,
    :addon_ore, :period_total_ore, keyword_init: true
  ) do
    def total_ore = base_ore + seats_ore + addon_ore
  end

  class LocalFixtureProvider
    def summarize(organization)
      billable = organization.billable_seats
      months = organization.billing_interval == "annual" ? ANNUAL_MONTHS_CHARGED : 1
      base = BASE_PLAN_ORE * months
      seats = billable * PER_SEAT_ORE * months
      addon = organization.automation_addon ? AUTOMATION_ADDON_ORE * months : 0

      Summary.new(
        interval: organization.billing_interval,
        active_seats: organization.active_seats,
        billable_seats: billable,
        base_ore: base,
        seats_ore: seats,
        addon_ore: addon,
        period_total_ore: base + seats + addon
      )
    end
  end

  # Integrated mode (BC-US-150 final milestone) swaps the provider for
  # the Billing Core-backed one without touching a single caller.
  def self.provider
    if BillingCore::Integration.enabled?
      @integrated_provider ||= BillingCore::Provider.new
    else
      @provider ||= LocalFixtureProvider.new
    end
  end

  def self.format_ore(ore)
    major, minor = ore.divmod(100)
    "#{major.to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ",")}.#{format('%02d', minor)} DKK"
  end
end
