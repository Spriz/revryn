Rails.application.routes.draw do
  root "organizations#index"

  get "register", to: "registrations#new"
  post "register", to: "registrations#create"
  get "login", to: "sessions#new", as: :login
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy", as: :logout

  resources :organizations, only: [:index, :new, :create]
  get "orgs/:slug", to: "organizations#show", as: :organization

  scope "orgs/:organization_slug" do
    get "members", to: "memberships#index", as: :organization_members
    patch "members/:id", to: "memberships#update", as: :organization_membership
    delete "members/:id", to: "memberships#destroy"
    post "invitations", to: "invitations#create", as: :organization_invitations
    post "invitations/:id/revoke", to: "invitations#revoke", as: :revoke_organization_invitation

    resources :companies, only: [:index, :create, :show], as: :organization_companies,
                          path: "companies"
    get "contacts", to: "contacts#index", as: :organization_contacts, defaults: { format: "html" }
    post "contacts", to: "contacts#create"
    get "contacts/:id", to: "contacts#show", as: :organization_contact, constraints: { id: /\d+/ }
    post "contacts/import", to: "contacts#import", as: :import_organization_contacts

    get "pipelines/:pipeline_id/deals", to: "deals#index", as: :organization_pipeline_deals
    post "deals", to: "deals#create", as: :organization_deals
    get "deals/:id", to: "deals#show", as: :organization_deal
    post "deals/:id/move", to: "deals#move", as: :move_organization_deal
    post "deals/:id/settle", to: "deals#settle", as: :settle_organization_deal

    post "notes", to: "notes#create", as: :organization_notes
    get "search", to: "searches#show", as: :organization_search
    get "activity", to: "activities#index", as: :organization_activity
    get "billing", to: "billing#show", as: :organization_billing
    patch "billing", to: "billing#update"
    post "billing/rollover", to: "billing#rollover", as: :rollover_organization_billing
  end

  get "invitations/:token", to: "invitations#show", as: :accept_invitation
  post "invitations/:token", to: "invitations#accept"

  get "up", to: "rails/health#show", as: :rails_health_check
end
