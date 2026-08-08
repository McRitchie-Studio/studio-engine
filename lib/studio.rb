require "studio/version"
require "studio/engine"
require "studio/color_scale"
require "studio/environment_banner"
require "studio/theme_resolver"
require "studio/ui_primitives"
require "studio/username_generator"
require "studio/s3"
require "studio/image_cache"
require "studio/link_token"
require "studio/email"
require "studio/email_smoke"
require "studio/mail_transport"
require "studio/redis"
require "studio/cable"

module Studio
  mattr_accessor :app_name,            default: "Studio"
  mattr_accessor :session_key,         default: :user_id
  mattr_accessor :welcome_message,     default: ->(user) { "Welcome, #{user.display_name}!" }
  mattr_accessor :registration_params, default: [:name, :email, :password, :password_confirmation]
  mattr_accessor :configure_new_user,  default: ->(user) {}
  mattr_accessor :configure_sso_user,  default: ->(user) {}
  mattr_accessor :sso_logo,            default: nil
  mattr_accessor :wallet_address_method, default: nil
  mattr_accessor :theme_logos,         default: []
  mattr_accessor :sticky_table_headers, default: false

  # ---- Smooth-load convention ---------------------------------------------
  # Opt-in per app: renders the view-transition + no-preview metas so Turbo 8
  # page swaps materialize behind the current page and present with a view
  # transition (layouts/studio/_smooth_load). OFF by default — an app with
  # known multi-second pages should fix those before opting in, because
  # no-preview holds the old page until the fresh response arrives.
  mattr_accessor :smooth_load,          default: false

  # Minimum ms the nav spinner stays visible once shown (_head.html.erb).
  # Apps wrapping multi-second operations in the spinner (e.g. Solana RPC)
  # keep the high default to avoid flicker; smooth-load apps typically drop
  # this to ~300 so fast loads never linger on a spinner.
  mattr_accessor :nav_spinner_min_ms,   default: 2500

  # ---- Authentication ------------------------------------------------------
  # Which sign-in methods this app offers. The shared login/signup views render
  # a button/field per enabled method (gate with Studio.auth_method?). Order is
  # display order. Both McRitchie Studio + Turf Monster are passwordless; legacy
  # email+password is opt-in via :password (which also re-arms the User#authenticate
  # contract check — see validate_user_contract!).
  mattr_accessor :auth_methods, default: %i[magic_link google wallet]

  # ---- Capability features --------------------------------------------------
  # Coarse app-level capability switches an app opts into. Distinct from
  # auth_methods (which sign-in methods the login views render) — these gate
  # whole product surfaces (e.g. :web3 on-chain features, :leveling XP/levels).
  # Default [] means every capability is OFF; an app turns on what it ships in
  # config/initializers/studio.rb:
  #
  #   Studio.configure { |config| config.features = %i[leveling web3] }
  #
  # Gate a surface with Studio.feature?(:leveling). The admin/style page uses this
  # to render capability-gated specimens "disabled but present" on apps with the
  # feature off (e.g. McRitchie Studio, which ships neither).
  mattr_accessor :features, default: []

  # Magic-link (passwordless email) tuning. token_name keys the MessageVerifier
  # purpose; bump it to invalidate every outstanding link. See MagicLink service.
  mattr_accessor :magic_link_ttl,        default: 15.minutes
  mattr_accessor :magic_link_token_name, default: "magic_link_v1"

  # Where magic-link tokens are stored / which URL scheme they use.
  #   :signed   (default) — stateless MessageVerifier MagicLink service; URL is
  #             /magic_link/<long token>. No table needed. Back-compat default.
  #   :database — a Studio::Link row; URL is the short /l/<token>. Requires the
  #             studio_links table (install the reference migration). The
  #             unified scheme both apps move to.
  mattr_accessor :magic_link_store, default: :signed

  # Whether Studio.routes draws the magic_link + solana wallet routes. An app that
  # already defines its own auth routes (e.g. turf-monster, which has battle-tested
  # magic_link/solana routes + extras) sets this false to avoid duplicate route
  # NAMES at boot, keeping its own routes intact. New consumers leave it true.
  mattr_accessor :draw_auth_routes, default: true

  # Whether Studio.routes draws the unified /l/<token> link routes
  # (Studio::LinksController — magic-link confirm/consume + referral redirect).
  # Default true; an app wanting its own /l handling sets this false and draws
  # its own routes (it can still reuse Studio::Link + Studio::LinkConsumption).
  mattr_accessor :draw_link_routes, default: true

  # Optional admin Act As / impersonation session conventions. Consumers that
  # include Studio::Impersonation get current_user layered over true_user with
  # these session keys, but still own authorization, audit logging, and routes.
  mattr_accessor :impersonation_target_session_key, default: :impersonated_user_id
  mattr_accessor :impersonation_actor_session_key,  default: :true_admin_id
  mattr_accessor :impersonation_started_at_session_key, default: :impersonation_started_at
  mattr_accessor :impersonation_max_minutes, default: 30

  # Default From: for engine-sent mail (magic links). Apps set this to their
  # verified sending address in config/initializers/studio.rb.
  mattr_accessor :mailer_from, default: nil
  mattr_accessor :resend_mailer_from, default: "McRitchie Studio <team@mcritchie.studio>"

  # Local/worktree email capture. nil means "auto": enabled when AGENT_WORKTREE
  # is truthy, otherwise disabled. Production always disables capture.
  mattr_accessor :local_email_capture, default: nil

  # Theme role colors (7 roles)
  mattr_accessor :theme_primary,  default: "#8E82FE"
  mattr_accessor :theme_dark,     default: "#1A1535"
  mattr_accessor :theme_light,    default: "#f8fafc"
  mattr_accessor :theme_success,  default: "#4BAF50"
  mattr_accessor :theme_warning,  default: "#FF7C47"
  mattr_accessor :theme_danger,   default: "#EF4444"
  mattr_accessor :theme_accent,   default: "#F72585"

  # S3 / object storage — host apps MUST set s3_bucket_prefix explicitly in
  # config/initializers/studio.rb before any S3-touching code runs (ImageCache,
  # Studio::S3.upload, etc.). Default is nil so external users don't accidentally
  # target someone else's bucket if they forget to configure.
  #
  # Bucket name resolves to "#{s3_bucket_prefix}-#{Rails.env.production? ? 'production' : 'dev'}".
  mattr_accessor :s3_bucket_prefix, default: nil
  mattr_accessor :s3_region,        default: "us-east-2"

  class S3ConfigError < StandardError; end

  # Whether to validate the host app's User model at boot. See docs/USER_CONTRACT.md.
  # Set to false in config/initializers/studio.rb to bypass (e.g. during migrations
  # that intentionally break the contract).
  mattr_accessor :validate_user_contract, default: true

  # Only methods that consumers must explicitly define are checked here.
  # Column accessors (#email, #name, #role) are NOT validated because
  # ActiveRecord defines them lazily — they don't appear on `.instance_methods`
  # until the schema is introspected (typically first record access). Missing
  # columns are caught by the User table schema, not by this validator.
  REQUIRED_USER_INSTANCE_METHODS = %i[admin? display_name].freeze
  REQUIRED_USER_CLASS_METHODS    = %i[find_by].freeze
  # #authenticate is only required when email+password sign-in is enabled.
  # Passwordless apps (the default) never call it.
  PASSWORD_USER_INSTANCE_METHODS = %i[authenticate].freeze

  class UserContractError < StandardError; end

  def self.configure
    yield self
  end

  def self.mailer_from_for_transport(env: ENV, ses_from:, resend_from: nil)
    if ses_transport_ready?(env)
      env_value(env, "MAILER_FROM") || ses_from
    else
      env_value(env, "RESEND_MAILER_FROM") || resend_from || resend_mailer_from
    end
  end

  def self.marketing_from_for_transport(env: ENV, ses_from:, resend_from: nil)
    if ses_transport_ready?(env)
      env_value(env, "MARKETING_MAILER_FROM") || ses_from
    else
      env_value(env, "RESEND_MARKETING_FROM") ||
        env_value(env, "RESEND_MAILER_FROM") ||
        resend_from ||
        resend_mailer_from
    end
  end

  def self.ses_transport_ready?(env = ENV)
    env["MAIL_TRANSPORT"].to_s.downcase == "ses" &&
      env_value(env, "SES_SMTP_USERNAME") &&
      env_value(env, "SES_SMTP_PASSWORD")
  end

  def self.env_value(env, key)
    value = env[key]
    value if value && !value.to_s.strip.empty?
  end

  # True when the given sign-in method is enabled for this app.
  def self.auth_method?(method)
    auth_methods.include?(method.to_sym)
  end

  # True when the given capability feature is enabled for this app. Mirrors
  # auth_method? — apps opt in via config.features in their initializer (see the
  # Studio.features accessor). Tolerates String or Symbol entries and any
  # Enumerable (Array or Set), so `feature?("web3")` and `feature?(:web3)` agree.
  def self.feature?(name)
    features.any? { |f| f.to_sym == name.to_sym }
  end

  # True when the engine login should render a PASSWORD field/form: passwords are enabled
  # (`:password` in auth_methods) AND the host User model actually supports them (responds to
  # `authenticate` — i.e. `has_secure_password`). Both are required, and the second is the
  # belt-and-suspenders: without it, a passwordless app (User with no `authenticate`) rendered
  # the hardcoded password field and 500'd on submit via `user.authenticate` — the whole fleet
  # having moved off passwords, this made the engine default wrong for every consumer. The User
  # check is defensive of a mis-set auth_methods; the contract validation normally guarantees it
  # (validate_user_contract! requires PASSWORD_USER_INSTANCE_METHODS iff auth_method?(:password)).
  def self.password_login_available?
    auth_method?(:password) && user_supports_password?
  end

  # Does the host User model respond to `authenticate` (has_secure_password)? Safe when no User
  # is defined (an engine-only boot / a test with no host model) — answers false rather than raise.
  def self.user_supports_password?
    return false unless defined?(::User) && ::User.respond_to?(:instance_methods)

    PASSWORD_USER_INSTANCE_METHODS.all? { |m| ::User.instance_methods.include?(m) }
  rescue StandardError
    false
  end

  # True when the emailed/inbox magic-link URL is the short /l/<token> — i.e.
  # magic links are Studio::Link rows AND this app draws the /l routes. False =
  # the legacy /magic_link/<token> path: the :signed store, OR an app on the
  # :database store that keeps its own /magic_link route (e.g. turf-monster,
  # whose /l is already its landing-page namespace).
  def self.magic_link_via_l_route?
    magic_link_store == :database && draw_link_routes
  end

  # The floor every developer-desk tool sits on: the local email inbox
  # (Studio::LocalEmailsController) and the local-review mint
  # (Studio::LocalReviewsController). Both hand out sign-in material without
  # authenticating anyone, so both are OFF in production and OFF for any request
  # that did not come from the loopback interface. One spelling, so a tool added
  # later cannot quietly ship a weaker gate. Pass request.local? in.
  def self.local_tool_enabled?(request_local:)
    return false if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?

    !!request_local
  end

  def self.local_email_capture?
    return false if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
    return !!local_email_capture unless local_email_capture.nil?

    env_truthy?(ENV["LOCAL_EMAIL_CAPTURE"]) || env_truthy?(ENV["AGENT_WORKTREE"])
  end

  # ---- Shared environment banner ------------------------------------------
  # Rules live in Studio::EnvironmentBanner (pure Ruby, unit-tested); these are
  # the Rails-aware entry points `studio/banners/_environment` calls. A host
  # renders that ONE partial instead of hand-rolling its own strip.

  # True for a stable QA app: Rails-production, but a non-production review
  # target that must identify itself as one. Keyed off QA_ENV, the signal the
  # release conductor already sets on every QA app.
  def self.qa_environment?
    EnvironmentBanner.qa_environment?
  end

  def self.show_environment_banner?(rails_env: rails_env_name)
    EnvironmentBanner.show?(rails_env: rails_env, qa_environment: qa_environment?)
  end

  def self.environment_banner_message(rails_env: rails_env_name, extra: [])
    EnvironmentBanner.message(rails_env: rails_env, qa_environment: qa_environment?, extra: extra)
  end

  # Whether the local email inbox is actually REACHABLE for this request, which
  # is the only honest reason to render a link to it. Deliberately the same
  # gate the controller enforces (local_tool_enabled?), so the banner can never
  # advertise a page that answers 404 — QA gets a status chip instead.
  def self.local_inbox_reachable?(request_local:)
    local_tool_enabled?(request_local: request_local)
  end

  def self.rails_env_name
    return "development" unless defined?(Rails) && Rails.respond_to?(:env)

    Rails.env.to_s
  end

  def self.user_wallet_address(user)
    return nil unless user

    [wallet_address_method, :wallet_address, :solana_address].compact.each do |method|
      next unless user.respond_to?(method)

      value = user.public_send(method)
      return value if value && !(value.respond_to?(:empty?) && value.empty?)
    end

    nil
  end

  # Verifies that the host app's User model satisfies the engine's expected
  # contract. Raises Studio::UserContractError with a clear pointer to
  # docs/USER_CONTRACT.md if anything required is missing. Called from
  # Engine#after_initialize. Opt out via Studio.validate_user_contract = false.
  def self.validate_user_contract!(user_class)
    return unless validate_user_contract
    return unless user_class.is_a?(Class)

    missing = []
    REQUIRED_USER_CLASS_METHODS.each do |m|
      missing << "User.#{m}" unless user_class.respond_to?(m)
    end
    instance_methods = REQUIRED_USER_INSTANCE_METHODS.dup
    instance_methods.concat(PASSWORD_USER_INSTANCE_METHODS) if auth_method?(:password)
    instance_methods.each do |m|
      missing << "User##{m}" unless user_class.instance_methods.include?(m)
    end

    return if missing.empty?

    raise UserContractError, <<~MSG
      The studio-engine gem's expected User model contract is not satisfied.

      Missing: #{missing.join(", ")}

      See the USER_CONTRACT.md doc in the studio-engine repo for the full
      contract + a minimal compliant example:
        https://github.com/McRitchie-Studio/studio-engine/blob/main/docs/USER_CONTRACT.md

      To bypass this check temporarily, set Studio.validate_user_contract = false
      in config/initializers/studio.rb.
    MSG
  end

  def self.theme_config
    {
      primary: theme_primary,
      dark:    theme_dark,
      light:   theme_light,
      success: theme_success,
      warning: theme_warning,
      danger:  theme_danger,
      accent:  theme_accent
    }.compact
  end

  # Find a logo from theme_logos by title, with fallback chain:
  # 1. Exact title match
  # 2. "Navbar Logo" fallback
  # 3. First logo in the list
  def self.logo_for(title)
    logos = theme_logos.map { |l| l.is_a?(Hash) ? l : { file: l, title: l } }
    entry = logos.find { |l| l[:title] == title }
    entry ||= logos.find { |l| l[:title] == "Navbar Logo" }
    entry ||= logos.first
    entry ? "/#{entry[:file]}" : nil
  end

  def self.env_truthy?(value)
    %w[1 true yes on].include?(value.to_s.strip.downcase)
  end

  def self.routes(router)
    router.instance_exec do
      get  "login",  to: "sessions#new"
      post "login",  to: "sessions#create"
      post "sso_continue", to: "sessions#sso_continue"
      get  "sso_login",    to: "sessions#sso_login"
      get  "logout", to: "sessions#destroy"
      get  "signup", to: "registrations#new"
      post "signup", to: "registrations#create"
      get  "auth/:provider/callback", to: "omniauth_callbacks#create"
      get  "auth/failure", to: "omniauth_callbacks#failure"

      # Developer-desk tools. Drawn outside production, and each controller
      # re-checks Studio.local_tool_enabled? per request (loopback only) — the
      # route being absent is the outer gate, not the only one.
      unless defined?(Rails) && Rails.env.production?
        get "_studio/local_emails", to: "studio/local_emails#index", as: :studio_local_emails
        get "_studio/local_review", to: "studio/local_reviews#show",  as: :studio_local_review
      end

      # Passwordless email (magic link). Helpers: magic_link_request_path (POST
      # to request a link), magic_link_path(token) / magic_link_url(token:)
      # for the emailed GET confirmation page, and magic_link_consume_path(token)
      # for the scanner-safe POST consume. The token is a URL-safe
      # MessageVerifier blob but the constraint guards against a stray "."
      # segment.
      if Studio.draw_auth_routes && Studio.auth_method?(:magic_link)
        post "magic_link",        to: "magic_links#create",   as: :magic_link_request
        get  "magic_link/:token", to: "magic_links#confirm",  as: :magic_link,
             constraints: { token: %r{[^/]+} }
        post "magic_link/:token", to: "magic_links#consume",  as: :magic_link_consume,
             constraints: { token: %r{[^/]+} }
      end

      # Unified short-token links — /l/<token> for magic sign-in links + referral
      # links (Studio::Link). Studio::LinksController dispatches by kind: a
      # magic_link renders the scanner-safe confirm interstitial then POSTs to
      # consume; a referral captures attribution + redirects. Helpers: link_path
      # / link_url(token:) and link_consume_path. Drawn for every consumer
      # (including draw_auth_routes=false apps) unless draw_link_routes is off.
      if Studio.draw_link_routes
        get  "l/:token", to: "studio/links#show",    as: :link,
             constraints: { token: %r{[^/]+} }
        post "l/:token", to: "studio/links#consume", as: :link_consume,
             constraints: { token: %r{[^/]+} }
      end

      # Solana / Phantom wallet sign-in (nonce challenge + signature verify).
      # The browser posts to these literal paths from the shared Connect-Wallet
      # flow; app-specific surfaces (mobile deep-link callback, account-linking,
      # OAuth popup) stay in the consuming app's routes.
      if Studio.draw_auth_routes && Studio.auth_method?(:wallet)
        get  "auth/solana/nonce",  to: "solana_sessions#nonce",  as: :solana_nonce
        post "auth/solana/verify", to: "solana_sessions#verify", as: :solana_verify
      end

      resources :error_logs, only: [:index, :show]

      # Admin
      get   "admin/theme",            to: "theme_settings#edit",       as: :admin_theme
      patch "admin/theme",            to: "theme_settings#update",     as: :admin_theme_update
      post  "admin/theme/regenerate", to: "theme_settings#regenerate", as: :admin_theme_regenerate
      get   "admin/schema",           to: "schema#index",              as: :admin_schema
      # The living style guide. Canonical at /admin/style (StyleController#index);
      # /admin/design_system redirects here but KEEPS its admin_design_system_path
      # helper so a shipped host sidebar link on the old helper still resolves.
      get   "admin/style",            to: "style#index",               as: :admin_style
      get   "admin/design_system",    to: redirect("/admin/style"),    as: :admin_design_system

      # Admin-managed transactional-email banner images (Studio::EmailImage).
      # index lists each managed email variant + its current banner; update
      # uploads a replacement. Surfaced from each app's admin hub.
      get   "admin/email_images",          to: "studio/email_images#index",  as: :admin_email_images
      patch "admin/email_images/:variant", to: "studio/email_images#update",  as: :admin_email_image,
            constraints: { variant: /[a-z_]+/ }

      # Model-page protocol (v1) — a reusable per-record inspector. Drawn into
      # every consuming app: /models/:model/:id renders one record as pretty JSON
      # plus a copy/paste rails-console command; /models/:model/random bounces to
      # a random record of that model. Admin-only (Studio::ModelsController).
      # Ships an EMPTY registry — a host enables a model in an initializer with
      # `Studio::ModelPage.register("release", Release, lookup: :slug)`. `random`
      # is drawn BEFORE `:id` so it is not captured as a record identifier.
      get "models/:model/random", to: "studio/models#random", as: :studio_model_random
      get "models/:model/:id",    to: "studio/models#show",   as: :studio_model
    end
  end
end
