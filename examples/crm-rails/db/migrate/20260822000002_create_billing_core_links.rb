class CreateBillingCoreLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_core_links do |t|
      t.references :organization, null: false, foreign_key: true, index: { unique: true }
      t.string :customer_ref, null: false
      t.string :contract_ref, null: false
      t.string :subscription_ref, null: false
      t.string :plan_version_ref, null: false
      t.timestamps
    end
  end
end
