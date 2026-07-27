# The living style guide — a single admin-gated page that renders the engine's
# shared UI primitives (buttons, surfaces, the seven motion primitives, and the
# theme role tokens) live in the host app's theme. Mirrors ThemeSettingsController:
# a plain host-inherited controller, gated by `require_admin` from the already-
# included Studio::ErrorHandling concern. The view is a bare content wrapper that
# renders inside each host's application.html.erb, so it inherits that app's
# navbar + theme automatically.
class DesignSystemController < ApplicationController
  before_action :require_admin

  def index; end
end
