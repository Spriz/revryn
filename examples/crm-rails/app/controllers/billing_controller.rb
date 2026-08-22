require "billing_seam"

class BillingController < ApplicationController
  before_action :require_login, :require_member

  def show
    @summary = BillingSeam.provider.summarize(current_organization)
  end

  # Admin knobs for the local billing fixtures (interval, add-on, seat
  # decrease timing) — all through the seam-backed settings.
  def update
    return head :forbidden unless current_membership.admin?

    current_organization.update!(
      billing_interval: %w[monthly annual].include?(params[:billing_interval]) ? params[:billing_interval] : current_organization.billing_interval,
      automation_addon: params[:automation_addon] == "1",
      seat_decrease_timing: %w[immediate period_end].include?(params[:seat_decrease_timing]) ? params[:seat_decrease_timing] : current_organization.seat_decrease_timing
    )
    redirect_to organization_billing_path(current_organization.slug)
  end

  # Models the period rollover: with period_end decrease timing, the
  # committed floor resets to the live seat count only here.
  def rollover
    return head :forbidden unless current_membership.admin?

    current_organization.update!(committed_seats: current_organization.active_seats)
    current_organization.record_activity!(current_user, "billing.period_rolled",
                                          "Started a new billing period")
    redirect_to organization_billing_path(current_organization.slug)
  end
end
