# Reference migration for the Studio::Link model. Like the engine's
# studio_email_deliveries migration, each consumer app installs its own copy of
# this into db/migrate (the adoption tasks do that) so the table is created in
# the app's database.
class CreateStudioLinks < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_links do |t|
      t.string :token, null: false
      t.string :kind, null: false
      # Polymorphic owner — the inviting User for referrals; nil for a magic
      # link to a not-yet-existent email (that email rides in metadata).
      t.references :linkable, polymorphic: true, index: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :expires_at
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :studio_links, :token, unique: true
    add_index :studio_links, :kind
    # Covers both "this owner's links" and "this owner's referral" lookups
    # (referral_for) via the leading columns.
    add_index :studio_links, [ :linkable_type, :linkable_id, :kind ],
              name: "idx_studio_links_owner_kind"
  end
end
