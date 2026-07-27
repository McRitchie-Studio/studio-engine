# The living style guide — a single admin-gated page that renders the engine's
# shared UI primitives (buttons, surfaces, the seven motion primitives, and the
# theme role tokens) live in the host app's theme. Mirrors ThemeSettingsController:
# a plain host-inherited controller, gated by `require_admin` from the already-
# included Studio::ErrorHandling concern. The view is a bare content wrapper that
# renders inside each host's application.html.erb, so it inherits that app's
# navbar + theme automatically.
class DesignSystemController < ApplicationController
  before_action :require_admin

  # Load the live theme so the Theme section (folded in from /admin/theme) shows
  # this app's saved colors + the CSRF-protected editor. Best-effort: the section
  # renders from Studio.theme_config defaults when no ThemeSetting row exists, so
  # a load hiccup must not take the whole living-style-guide page down.
  def index
    @theme_setting  = ThemeSetting.current if defined?(ThemeSetting)
    @theme_defaults = Studio.theme_config  if Studio.respond_to?(:theme_config)
  rescue StandardError => e
    Rails.logger.warn("[design_system] theme preload skipped: #{e.message}")
  end
end
