class DealsController < ApplicationController
  before_action :require_login, :require_member

  def index
    @pipeline = current_organization.pipelines.includes(stages: { deals: [:company, :owner] })
                                    .find(params[:pipeline_id])
  end

  def create
    stage = stage_in_org(params[:stage_id])
    deal = current_organization.deals.create(
      title: params[:title], stage: stage,
      amount_ore: params[:amount_ore].to_i,
      company_id: company_id_in_org(params[:company_id]),
      owner: current_user, closes_on: params[:closes_on].presence
    )
    if deal.persisted?
      current_organization.record_activity!(current_user, "deal.created",
                                            "Opened deal #{deal.title}")
    end
    redirect_to organization_pipeline_deals_path(current_organization.slug, stage.pipeline_id)
  end

  def show
    @deal = current_organization.deals.find(params[:id])
    @notes = @deal.notes.includes(:author).order(created_at: :desc)
    @stages = @deal.stage.pipeline.stages
  end

  def move
    deal = current_organization.deals.find(params[:id])
    stage = stage_in_org(params[:stage_id])
    from = deal.stage.name
    deal.update!(stage: stage)
    current_organization.record_activity!(current_user, "deal.moved",
                                          "Moved #{deal.title} from #{from} to #{stage.name}")
    redirect_back fallback_location: organization_deal_path(current_organization.slug, deal)
  end

  def settle
    deal = current_organization.deals.find(params[:id])
    status = params[:status]
    return head :unprocessable_entity unless %w[won lost].include?(status)

    deal.update!(status: status)
    current_organization.record_activity!(current_user, "deal.#{status}",
                                          "Marked #{deal.title} as #{status}")
    redirect_back fallback_location: organization_deal_path(current_organization.slug, deal)
  end

  private

  def stage_in_org(stage_id)
    Stage.joins(:pipeline).where(pipelines: { organization_id: current_organization.id })
         .find(stage_id)
  end

  def company_id_in_org(company_id)
    return nil if company_id.blank?

    current_organization.companies.find(company_id).id
  end
end
