class ThemeSetting < ApplicationRecord
  include Sluggable

  ROLES = %i[primary dark light success warning danger accent].freeze

  # Map DB columns (accent1/accent2) to role names (success/accent)
  def self.db_column_for(role)
    { success: :accent1, accent: :accent2 }[role] || role
  end

  validates :app_name, presence: true, uniqueness: true
  # Every page's head runs these through Studio::ColorScale, which reads six hex
  # digits. A saved "#abc" would answer 500 on every page, the editor included.
  validates(*ROLES.map { |role| db_column_for(role) }, format: { with: /\A#\h{6}\z/, message: "must be a #rrggbb colour" }, allow_blank: true)

  # Returns the ThemeSetting for the current app, or a new unsaved instance.
  def self.current
    find_by(app_name: Studio.app_name) || new(app_name: Studio.app_name)
  end

  # Merged colors: DB values override Studio.theme_config defaults.
  def resolved_colors
    defaults = Studio.theme_config
    ROLES.each_with_object({}) do |role, hash|
      db_val = read_attribute(self.class.db_column_for(role))
      hash[role] = db_val.presence || defaults[role]
    end.compact
  end

  def name_slug
    "theme-#{app_name.parameterize}"
  end
end
