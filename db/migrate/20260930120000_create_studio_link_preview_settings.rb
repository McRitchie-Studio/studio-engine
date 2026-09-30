# The operator's link-preview DEFAULT for one app: the title, description and
# image an unfurl (iMessage, Slack, Discord, X...) shows for any page that does
# not name its own. Set at /admin/link_preview.
#
# One row per app (Studio.app_name), like studio_geo_settings. The IMAGE is not a
# column: it is an Active Storage attachment (Studio::LinkPreviewSetting#image),
# which rides the host's active_storage_* tables.
#
# INSTALLING THIS TABLE TURNS THE ENGINE'S HEAD TAGS ON under the default
# Studio.link_preview_tags = :auto. An app that already emits its own og tags
# sets `config.link_preview_tags = false` before migrating, or deletes its own.
class CreateStudioLinkPreviewSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :studio_link_preview_settings do |t|
      t.string :app_name, null: false
      t.string :title
      t.text   :description

      # Sluggable, like every other Studio settings row.
      t.string :slug

      t.timestamps
    end

    add_index :studio_link_preview_settings, :app_name, unique: true
    add_index :studio_link_preview_settings, :slug, unique: true
  end
end
