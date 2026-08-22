class CreateCoreSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false, index: { unique: true }
      t.string :password_digest, null: false
      t.string :full_name, default: ""
      t.timestamps
    end

    create_table :organizations do |t|
      t.string :name, null: false
      t.string :slug, null: false, index: { unique: true }
      # Billing seam settings (local fixtures until integration):
      t.string :billing_interval, null: false, default: "monthly" # monthly | annual
      t.boolean :automation_addon, null: false, default: false
      t.string :seat_decrease_timing, null: false, default: "period_end" # immediate | period_end
      t.integer :committed_seats, null: false, default: 0
      t.timestamps
    end

    create_table :memberships do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false, default: "member" # owner | admin | member
      t.string :status, null: false, default: "active" # active | removed
      t.timestamps
      t.index [:organization_id, :user_id], unique: true
    end

    create_table :invitations do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :email, null: false
      t.string :role, null: false, default: "member"
      t.string :token, null: false, index: { unique: true }
      t.references :invited_by, foreign_key: { to_table: :users }
      t.datetime :accepted_at
      t.datetime :revoked_at
      t.timestamps
    end

    create_table :companies do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.string :domain, default: ""
      t.string :city, default: ""
      t.timestamps
      t.index [:organization_id, :name]
    end

    create_table :contacts do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :company, foreign_key: true
      t.string :full_name, null: false
      t.string :email, default: ""
      t.string :phone, default: ""
      t.string :title, default: ""
      t.timestamps
      t.index [:organization_id, :full_name]
    end

    create_table :pipelines do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end

    create_table :stages do |t|
      t.references :pipeline, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :deals do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :company, foreign_key: true
      t.references :contact, foreign_key: true
      t.references :stage, null: false, foreign_key: true
      t.references :owner, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.integer :amount_ore, null: false, default: 0 # integer minor units, never floats
      t.string :status, null: false, default: "open" # open | won | lost
      t.date :closes_on
      t.timestamps
    end

    create_table :notes do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.references :notable, polymorphic: true, null: false
      t.text :body, null: false
      t.timestamps
    end

    create_table :activities do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :users }
      t.string :verb, null: false
      t.string :summary, null: false
      t.timestamps
      t.index [:organization_id, :created_at]
    end
  end
end
