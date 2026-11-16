# frozen_string_literal: true

class CreateSantanderMxItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :santander_mx_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :base_url, null: false
      t.text :api_token, null: false

      t.date :sync_start_date
      t.date :transactions_synced_through

      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false

      t.timestamps
    end

    add_index :santander_mx_items, :status

    create_table :santander_mx_accounts, id: :uuid do |t|
      t.references :santander_mx_item, null: false, foreign_key: true, type: :uuid

      t.string :name, null: false
      t.string :last4
      t.string :currency

      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :santander_mx_accounts, [ :santander_mx_item_id, :name ], unique: true,
              name: "index_santander_mx_accounts_on_item_and_name"
  end
end
