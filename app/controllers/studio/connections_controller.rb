# frozen_string_literal: true

module Studio
  # The engine's own home for a provider's connect, callback and disconnect
  # (Studio::ConnectionFlow), for a host that serves the provider's page from
  # elsewhere or not at all. Studio.draw_connection_routes points here unless
  # the host names its own controller. It inherits the host's
  # ApplicationController, so the host's layout, session, current_user and
  # Studio::ErrorHandling (rescue_and_log, require_admin) apply.
  class ConnectionsController < ::ApplicationController
    include Studio::ConnectionFlow
  end
end
