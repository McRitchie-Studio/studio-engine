# The living style guide — a single admin-gated page (/admin/style) that renders
# the engine's shared UI primitives (buttons, surfaces, the seven motion
# primitives, the leveling badges, and the theme role tokens) live in the host
# app's theme. Mirrors ThemeSettingsController: a plain host-inherited controller,
# gated by `require_admin` from the already-included Studio::ErrorHandling concern.
# The view is a bare content wrapper that renders inside each host's
# application.html.erb, so it inherits that app's navbar + theme automatically.
#
# Reached at /admin/style (helper admin_style_path).
class StyleController < ApplicationController
  before_action :require_admin

  # The Loaders section's live infinite-scroll specimen: a demo feed of
  # LOADERS_FEED_PAGES pages (style/_loaders_feed_page).
  LOADERS_FEED_PAGES = 3
  LOADERS_FEED_PER_PAGE = 4

  # Load the live theme so the Theme section (the landing section) shows this app's saved colors + the CSRF-protected editor.
  # Best-effort: the section renders from Studio.theme_config defaults when no
  # ThemeSetting row exists, so a load hiccup must not take the whole page down.
  def index
    @theme_setting  = ThemeSetting.current if defined?(ThemeSetting)
    @theme_defaults = Studio.theme_config  if Studio.respond_to?(:theme_config)
  rescue StandardError => e
    Rails.logger.warn("[style] theme preload skipped: #{e.message}")
  end

  # One page of the demo feed, at /admin/style/loaders_feed?page=N.
  def loaders_feed
    @page = params[:page].to_i.clamp(1, LOADERS_FEED_PAGES)
  end
end
