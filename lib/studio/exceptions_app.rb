# frozen_string_literal: true

require "action_dispatch"

module Studio
  # The friendly not-found page, as an exceptions app. An app opts in with one
  # line in config/application.rb (docs/NOT_FOUND_PAGE.md):
  #
  #   config.exceptions_app = Studio::ExceptionsApp.new
  #
  # Rails hands this app every exception ShowExceptions renders, with PATH_INFO
  # rewritten to "/<status>" and the method set to GET. That is the path a
  # RoutingError takes (an unknown address) and the path a RecordNotFound takes
  # (Studio::ErrorHandling#handle_not_found re-raises on purpose so it lands here).
  #
  # What it answers:
  #
  #   404, an HTML request   Studio::NotFoundController#show: the app's name and
  #                          brand mark, a short message and a button home,
  #                          inside the app's own layout. Status 404.
  #   404, a data request    ActionDispatch::PublicExceptions, unchanged: a JSON
  #                          request gets {"status":404,"error":"Not Found"} with
  #                          status 404, never the HTML page.
  #   any other status       ActionDispatch::PublicExceptions, unchanged (500,
  #                          422 and the rest keep public/<status>.html).
  #
  # IT CANNOT LOOP AND IT CANNOT CHANGE THE STATUS. The page renders through the
  # app's ApplicationController, so the app's before_actions, layout and database
  # all run. If any of them raises, or answers anything but a 404 (a sign-in
  # redirect from a wall that does not list the page, a 406 from allow_browser),
  # the answer is thrown away and PublicExceptions serves public/404.html, the
  # static last resort, with status 404. PublicExceptions only reads a file, so
  # the fallback has nothing left that can fail into this app again.
  #
  # Which requests are HTML is PublicExceptions' own rule, so the split never
  # drifts from Rails': a format whose body PublicExceptions can serialize (JSON,
  # XML) is data, and everything else, `Accept: */*` included, is the page.
  class ExceptionsApp
    NOT_FOUND = 404
    PAGE_PARAMS = { controller: "studio/not_found", action: "show" }.freeze
    # Cached by the failed request; the page's request must not read them.
    STALE_KEYS = %w[action_dispatch.request.path_parameters
                    action_dispatch.request.parameters
                    action_dispatch.request.query_parameters
                    action_dispatch.request.request_parameters
                    action_controller.instance].freeze

    # public_path: where the static pages live. Defaults to Rails.public_path,
    # read on each call, so the line works before the app finishes booting.
    # page: the Rack endpoint that draws the page (a seam for tests).
    def initialize(public_path = nil, page: nil)
      @public_path = public_path
      @page = page
    end

    def call(env)
      return static(env) unless page_request?(env)

      response = draw_page(env)
      return response if response

      static(env)
    end

    private

    def page_request?(env)
      request = ActionDispatch::Request.new(env)
      return false unless request.path_info.delete_prefix("/").to_i == NOT_FOUND

      html?(request)
    end

    # PublicExceptions renders a body in a format the error hash serializes to
    # (to_json, to_xml) and the HTML file for anything else.
    def html?(request)
      content_type = begin
        request.formats.first
      rescue ActionDispatch::Http::MimeNegotiation::InvalidType
        Mime[:text]
      end
      return true unless content_type

      !{}.respond_to?("to_#{content_type.to_sym}")
    end

    # The page's answer, or nil when it raised or came back as anything but a
    # 404 HTML page.
    def draw_page(env)
      page_env = env.except(*STALE_KEYS)
      page_env["action_dispatch.request.path_parameters"] = PAGE_PARAMS.dup
      status, headers, body = page.call(page_env)
      return [status, headers, body] if status.to_i == NOT_FOUND && html_body?(headers)

      body.close if body.respond_to?(:close)
      log("answered #{status}, not 404")
      nil
    rescue StandardError, ScriptError => e
      log("#{e.class}: #{e.message}")
      nil
    end

    def html_body?(headers)
      type = headers["content-type"] || headers["Content-Type"]
      type.to_s.start_with?("text/html")
    end

    def page
      @page || Studio::NotFoundController.action(:show)
    end

    def static(env)
      ActionDispatch::PublicExceptions.new(public_path).call(env)
    end

    def public_path
      (@public_path || Rails.public_path).to_s
    end

    def log(reason)
      Rails.logger&.warn("[studio.not_found] the page fell back to public/404.html: #{reason}")
    end
  end
end
