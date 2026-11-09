# frozen_string_literal: true

module Studio
  # The admin integrations page (docs/INTEGRATIONS.md): every integration the
  # host enabled with Studio.enable_integration, its status and its Connect,
  # and one page per integration with its connections, Disconnect, and the
  # host's own panel. Studio.draw_integrations_routes points here.
  #
  # It includes Studio::ConnectionFlow, so connect, callback and disconnect are
  # the connection tooling's own, and the host's admin guard
  # (Studio.connection_admin_guard) runs before EVERY action here, the list
  # and the pages included. It inherits the host's ApplicationController: its
  # layout, session, current_user and Studio::ErrorHandling apply.
  class IntegrationsController < ::ApplicationController
    include Studio::ConnectionFlow

    helper_method :integration_path_for, :integration_connect_path, :integration_callback_url,
                  :integration_disconnect_path, :integrations_index_path

    def index
      @integrations = Studio::Integrations.all
    end

    def show
      @integration = Studio::Integrations.fetch(params[:studio_connection])
      @connections = @integration.connections
    end

    private

    def integration_route(integration) = Studio::Connections.route(integration.key)

    def integration_path_for(integration) = public_send(:"#{integration_route(integration).as}_path")
    def integration_connect_path(integration) = public_send(:"#{integration_route(integration).as}_connect_path")
    def integration_callback_url(integration) = public_send(:"#{integration_route(integration).as}_callback_url")

    def integration_disconnect_path(integration, connection)
      public_send(:"#{integration_route(integration).as}_disconnect_path", connection)
    end

    def integrations_index_path = "/#{Studio::Integrations.mount_path}"
  end
end
