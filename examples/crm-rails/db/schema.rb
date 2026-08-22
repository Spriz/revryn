# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_22_000002) do
  create_table "activities", force: :cascade do |t|
    t.integer "actor_id"
    t.datetime "created_at", null: false
    t.integer "organization_id", null: false
    t.string "summary", null: false
    t.datetime "updated_at", null: false
    t.string "verb", null: false
    t.index ["actor_id"], name: "index_activities_on_actor_id"
    t.index ["organization_id", "created_at"], name: "index_activities_on_organization_id_and_created_at"
    t.index ["organization_id"], name: "index_activities_on_organization_id"
  end

  create_table "billing_core_links", force: :cascade do |t|
    t.string "contract_ref", null: false
    t.datetime "created_at", null: false
    t.string "customer_ref", null: false
    t.integer "organization_id", null: false
    t.string "plan_version_ref", null: false
    t.string "subscription_ref", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_billing_core_links_on_organization_id", unique: true
  end

  create_table "companies", force: :cascade do |t|
    t.string "city", default: ""
    t.datetime "created_at", null: false
    t.string "domain", default: ""
    t.string "name", null: false
    t.integer "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "name"], name: "index_companies_on_organization_id_and_name"
    t.index ["organization_id"], name: "index_companies_on_organization_id"
  end

  create_table "contacts", force: :cascade do |t|
    t.integer "company_id"
    t.datetime "created_at", null: false
    t.string "email", default: ""
    t.string "full_name", null: false
    t.integer "organization_id", null: false
    t.string "phone", default: ""
    t.string "title", default: ""
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_contacts_on_company_id"
    t.index ["organization_id", "full_name"], name: "index_contacts_on_organization_id_and_full_name"
    t.index ["organization_id"], name: "index_contacts_on_organization_id"
  end

  create_table "deals", force: :cascade do |t|
    t.integer "amount_ore", default: 0, null: false
    t.date "closes_on"
    t.integer "company_id"
    t.integer "contact_id"
    t.datetime "created_at", null: false
    t.integer "organization_id", null: false
    t.integer "owner_id"
    t.integer "stage_id", null: false
    t.string "status", default: "open", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_deals_on_company_id"
    t.index ["contact_id"], name: "index_deals_on_contact_id"
    t.index ["organization_id"], name: "index_deals_on_organization_id"
    t.index ["owner_id"], name: "index_deals_on_owner_id"
    t.index ["stage_id"], name: "index_deals_on_stage_id"
  end

  create_table "invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.integer "invited_by_id"
    t.integer "organization_id", null: false
    t.datetime "revoked_at"
    t.string "role", default: "member", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["organization_id"], name: "index_invitations_on_organization_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "organization_id", null: false
    t.string "role", default: "member", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["organization_id", "user_id"], name: "index_memberships_on_organization_id_and_user_id", unique: true
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "notes", force: :cascade do |t|
    t.integer "author_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.integer "notable_id", null: false
    t.string "notable_type", null: false
    t.integer "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_notes_on_author_id"
    t.index ["notable_type", "notable_id"], name: "index_notes_on_notable"
    t.index ["organization_id"], name: "index_notes_on_organization_id"
  end

  create_table "organizations", force: :cascade do |t|
    t.boolean "automation_addon", default: false, null: false
    t.string "billing_interval", default: "monthly", null: false
    t.integer "committed_seats", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "seat_decrease_timing", default: "period_end", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
  end

  create_table "pipelines", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "organization_id", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_pipelines_on_organization_id"
  end

  create_table "stages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "pipeline_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["pipeline_id"], name: "index_stages_on_pipeline_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "full_name", default: ""
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "activities", "organizations"
  add_foreign_key "activities", "users", column: "actor_id"
  add_foreign_key "billing_core_links", "organizations"
  add_foreign_key "companies", "organizations"
  add_foreign_key "contacts", "companies"
  add_foreign_key "contacts", "organizations"
  add_foreign_key "deals", "companies"
  add_foreign_key "deals", "contacts"
  add_foreign_key "deals", "organizations"
  add_foreign_key "deals", "stages"
  add_foreign_key "deals", "users", column: "owner_id"
  add_foreign_key "invitations", "organizations"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "memberships", "organizations"
  add_foreign_key "memberships", "users"
  add_foreign_key "notes", "organizations"
  add_foreign_key "notes", "users", column: "author_id"
  add_foreign_key "pipelines", "organizations"
  add_foreign_key "stages", "pipelines"
end
