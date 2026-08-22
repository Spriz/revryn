# Integration-mode switch (BC-US-150 final milestone, BC-US-153).
# Integrated mode is opt-in via environment; standalone remains the
# default and keeps its full behavior and test suite (INV-031).
module BillingCore
  module Integration
    def self.enabled? = ENV["KYSTVEJ_BILLING"] == "integrated"

    def self.config
      {
        url: ENV.fetch("BILLING_CORE_URL", "http://localhost:4000"),
        token: ENV.fetch("BILLING_CORE_TOKEN", ""),
        team_id: ENV.fetch("BILLING_CORE_TEAM_ID", "")
      }
    end
  end
end
