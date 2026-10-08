# frozen_string_literal: true

require "active_support/security_utils"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/module/attribute_accessors"

module Studio
  # The component gallery: Lookbook, mounted by Studio.routes at
  # /admin/style/components, rendering the ViewComponent previews under the
  # engine's app/components/previews (docs/FRONT_END_STANDARD.md, "Components").
  #
  # Three rules hold it, each here so the routes, the engine initializers and
  # the preview controller read one answer:
  #
  # 1. WHERE IT IS DRAWN. Only in an app whose bundle loads lookbook (the
  #    engine never requires it; a host adds `gem "lookbook"` after
  #    studio-engine). Such an app draws it in development and test, and in
  #    production only if it also sets Studio.lookbook_in_production = true.
  #    A host that lists lookbook BEFORE studio-engine draws nothing and is
  #    told so at boot (LOAD_ORDER_WARNING).
  #    Everywhere else there is no route, no ViewComponent preview route, no
  #    /lookbook-assets middleware, and no Lookbook in memory.
  # 2. WHO SEES IT. An admin with a live session. Anyone else gets 404, not a
  #    redirect, so the gallery's existence is not advertised. The check runs
  #    in the router (AdminConstraint), because Lookbook's controllers inherit
  #    ActionController::Base and never run the host's before_actions.
  # 3. WHAT IT SHOWS. The rendered preview and its HTML. The Source and Params
  #    panels are switched off, embeds are off, pages are off, and no preview
  #    declares a @param tag, so the gallery shows no Ruby and accepts no input.
  module ComponentGallery
    MOUNT_PATH = "/admin/style/components"
    # ViewComponent's own preview pages, moved from /rails/view_components to
    # sit behind the same wall (Studio::ComponentPreviewsController).
    PREVIEWS_ROUTE = "/admin/style/previews"
    PREVIEWS_CONTROLLER = "Studio::ComponentPreviewsController"
    # Lookbook's UI references its scripts and styles at this absolute path.
    ASSETS_PATH = "/lookbook-assets"
    # The layout each preview renders in: the host's stylesheets and theme, no
    # navbar, no script.
    PREVIEW_LAYOUT = "studio/component_preview"
    # Only the panels that show output. Lookbook's defaults add :source (the
    # preview's Ruby and template) and :params (live inputs from the URL).
    MAIN_PANELS = %i[preview output].freeze
    DRAWER_PANELS = %i[notes].freeze
    # Printed at boot by a host whose bundle loads lookbook before the engine.
    LOAD_ORDER_WARNING =
      "studio-engine: lookbook was required before studio-engine, so the component gallery " \
      "(#{MOUNT_PATH}) is NOT mounted. Move `gem \"lookbook\"` below `gem \"studio-engine\"` " \
      "in the Gemfile and restart."

    module_function

    # Whether the engine saw Lookbook already loaded when it was required, which
    # means the host listed lookbook BEFORE studio-engine (set by
    # lib/studio/engine.rb).
    mattr_accessor :lookbook_loaded_before_engine, default: false

    # Whether this app draws the gallery. Pure: the env, the flag, whether
    # lookbook is loaded and whether it loaded in order are passed in, so the
    # rule unit-tests without Rails. Out of order it is not drawn: Lookbook
    # turned previews on before ViewComponent decided its preview routes.
    def mounted?(env:, in_production:, lookbook_loaded:, load_order_ok: true)
      return false unless lookbook_loaded
      return false unless load_order_ok

      !env.to_s.casecmp?("production") || in_production == true
    end

    # Whether the host's bundle loaded Lookbook. The engine never requires it.
    def lookbook_loaded?
      defined?(::Lookbook::Engine) ? true : false
    end

    # Lookbook required after view_component, so ViewComponent's after_initialize
    # draws (or does not draw) its preview routes before Lookbook turns previews on.
    def load_order_ok?
      !lookbook_loaded_before_engine
    end

    # Whether this request comes from an admin with a live session. It reads the
    # same two facts the engine's own gate reads: the user id under
    # Studio.session_key (Studio::ErrorHandling#current_user), and, for a User
    # with a session_token column, a cookie token that matches it
    # (#verify_session_token). It fails closed: no session, no user, a non-admin,
    # or a stale token all answer false.
    def admin_request?(request)
      session = request.session
      key = Studio.session_key
      user_id = session[key.to_s] || session[key.to_sym]
      return false if user_id.blank?
      return false unless defined?(::User)

      user = ::User.find_by(id: user_id)
      return false unless user.respond_to?(:admin?) && user.admin?
      return true unless user.respond_to?(:session_token)

      token = user.session_token.to_s
      token.present? && ActiveSupport::SecurityUtils.secure_compare(token, session[:session_token].to_s)
    end

    # The directory Lookbook's own Rack::Static served ASSETS_PATH from.
    def lookbook_assets_root
      ::Lookbook::Engine.root.join("public/lookbook-assets").to_s
    end

    # The routing constraint on the mount. A request it refuses matches no
    # route, which Rails answers 404.
    class AdminConstraint
      def matches?(request)
        ComponentGallery.admin_request?(request)
      end
    end

    # The settings that keep the gallery to output only (rule 3). Applied by
    # the studio.component_gallery initializer, before the host's own
    # initializers, so a host can still change one deliberately.
    def configure_lookbook!(config)
      config.project_name = "Components"
      config.preview_inspector.main_panels = MAIN_PANELS
      config.preview_inspector.drawer_panels = DRAWER_PANELS
      config.preview_embeds.enabled = false
      config.page_paths = []
      config.live_updates = false
      config.debug_menu = false
      # Parse previews on the first gallery request, not at boot: an app that
      # never opens the gallery pays nothing for it.
      config.lazy_load_previews_and_pages = true
      config
    end
  end
end
