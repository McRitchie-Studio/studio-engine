require "studio/version"
require "studio/log_rotation"
require "studio/ip_locations"
require "studio/geo"
require "studio/geo/lookup"
require "studio/engine"
require "studio/color_scale"
require "studio/environment_banner"
require "studio/theme_resolver"
require "studio/ui_primitives"
require "studio/sidebar_sections"
require "studio/profile_sections"
require "studio/profile_image"
require "studio/oauth_identity"
require "studio/newsletter"
require "studio/username_generator"
require "studio/s3"
require "studio/image_cache"
require "studio/link_token"
require "studio/link_resolution"
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

  # Called after a newsletter subscribe or unsubscribe on /profile, so a host can
  # react without the engine knowing anything about what it does.
  #
  # THE REASON THIS EXISTS, stated concretely: turf-monster pays a 25-seed welcome
  # bonus on-chain, gated on `first_newsletter_join?` — literally
  # `joined_email_list_at.nil?`. The engine's subscribe action sets that column
  # and told nobody, so a subscribe from /profile granted no seeds AND made the
  # once-ever bonus unclaimable forever. Turf had to hold the row off its profile
  # page entirely. This is what lets it come back.
  #
  #   Studio.after_newsletter_change = lambda do |user, subscribed:, first_join:|
  #     GrantWelcomeSeeds.call(user) if subscribed && first_join
  #   end
  #
  # `first_join:` is computed BEFORE the write, because the write is what sets the
  # column — asking afterwards always answers false.
  #
  # A raising callback CANNOT undo the subscription: the subscription is the
  # durable fact and the reaction is not. Turf's grant goes over RPC to a chain
  # that is sometimes unreachable, and a failed bonus must not cost someone their
  # place on the mailing list.
  mattr_accessor :after_newsletter_change, default: ->(_user, subscribed:, first_join:) {}
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

  # ---- Sidebar navigation ----
  # Out-of-the-box navigation: the engine navbar mounts a link-sidebar trigger
  # and slide-out panel when the host declares sections here. The default []
  # renders NOTHING, so existing consumers see no change on upgrade until they
  # opt in. Accepts a static Array of section hashes or a callable (receives
  # the view context) for dynamic sections — route helpers, logged_in? walls.
  # Sections flagged admin: true render only for admin? viewers. Shape and
  # resolution rules: lib/studio/sidebar_sections.rb.
  #
  #   Studio.configure do |config|
  #     config.sidebar_sections = ->(view) {
  #       [ { title: "Site", links: [
  #             { label: "Home", href: view.root_path, emoji: "🏠" } ] } ]
  #     }
  #   end
  mattr_accessor :sidebar_sections, default: []

  # ---- The shared profile page (/profile) ----
  # The rows that make up /profile. `nil` — the default — means "the engine's
  # standard page", NOT "no rows": a brand-new app with an empty initializer gets
  # a working profile page, which is the entire point of standardizing it.
  #
  # Declare an Array (or a callable receiving the view) to customize. Compose
  # against Studio.default_profile_sections rather than a literal, so a later
  # engine release that adds a standard row delivers it to you:
  #
  #   Studio.configure do |config|
  #     config.profile_sections = ->(view) {
  #       Studio.default_profile_sections +
  #         [ { key: :wallet, title: "Identities", partial: "profiles/wallet" } ]
  #     }
  #   end
  #
  # Drop a standard row by key instead of restating the list:
  #
  #   config.profile_sections = Studio.default_profile_sections.reject { |s| s[:key] == :avatar }
  #
  # Shape and resolution rules: lib/studio/profile_sections.rb. A row may declare
  # `requires:` — an attribute the current user must respond to — and is dropped
  # when this host's model does not have it, so the page tolerates the fact that
  # the consuming apps' users tables genuinely disagree.
  mattr_accessor :profile_sections, default: nil

  # Whether Studio.routes draws /profile (Studio::ProfilesController).
  #
  # ON BY DEFAULT, and it is worth saying why this one can be when
  # draw_admin_emails_routes and draw_onboarding_routes could not: those two
  # claimed helper names a consumer ALREADY OWNED, so drawing them raised
  # `Invalid route name, already in use` while that app's routes.rb loaded and
  # took down its entire route set. `profile` is claimed by none of the five
  # consumers — mcritchie-studio, mcritchie-industries, turf-monster, moms-app
  # and acquisition-studio were each checked (2026-08-14) — and turf-monster's
  # nearest names are complete_profile_account_path / save_profile_account_path,
  # which do not collide.
  #
  # That is exactly why the shared page is /profile and not /account: turf owns
  # account_path, and a shared /account could never be default-on. An app that
  # wants the page gone still sets this false.
  mattr_accessor :draw_profile_routes, default: true

  # How long a freshly minted magic link stays live.
  mattr_accessor :magic_link_ttl, default: 15.minutes

  # RETIRED (0.31.0) — kept only so an initializer that still sets it boots.
  # It named the MessageVerifier purpose for the old :signed store, which no
  # longer exists. Delete the line from your initializer.
  mattr_accessor :magic_link_token_name, default: "magic_link_v1"

  # RETIRED (0.31.0) — magic links are ALWAYS Studio::Link rows now, so this
  # reads :database and nothing else. Assigning :signed raises rather than
  # silently downgrading: that store minted a ~350-character MessageVerifier
  # blob whose EXPIRED form cannot be decoded, so an app on it could not tell
  # whose dead link it was holding — which is exactly the fact
  # Studio::LinkResolution needs to leave a live session alone. Requires the
  # studio_links table, installed by `bin/rails studio_engine:install:migrations`
  # (never hand-copied — a hand copy collides with the task's own copy on
  # `class CreateStudioLinks`).
  mattr_reader :magic_link_store, default: :database

  # `to_s.to_sym`, not `to_sym`: this runs from an initializer, and nil or an
  # Integer would raise NoMethodError — swallowing the explanation below with a
  # message that says nothing about what to do. A blank falls through to the
  # raise instead, so the operator reads the actual instruction.
  def self.magic_link_store=(value)
    return if value.to_s.to_sym == :database

    raise ArgumentError,
          "Studio.magic_link_store = #{value.inspect} is retired (studio-engine 0.31.0). " \
          "Magic links are Studio::Link rows served at /l/<token>. Delete this line from " \
          "config/initializers/studio.rb, then install the table with " \
          "`bin/rails studio_engine:install:migrations && bin/rails db:migrate` — in that " \
          "order, because this raise fires while the initializer loads and no rake task can " \
          "boot until the line is gone."
  end

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

  # Draw the shared transactional-email page at /admin/emails
  # (Studio::EmailsController). OFF by default because the path AND its helper
  # names (admin_emails_path / admin_email_path) are already taken in
  # turf-monster, where drawing them raises at route-load and kills every route
  # in the app. A host opts in from config/initializers/studio.rb:
  #
  #   config.draw_admin_emails_routes = true
  #
  # Gates only the PAGE. Studio::EmailImage's registry and its inherited-default
  # resolution are always on, so an app sends branded email either way.
  mattr_accessor :draw_admin_emails_routes, default: false

  # Draw the shared first-name onboarding endpoints
  # (Studio::OnboardingController#first_name / #skip_first_name). OFF by default,
  # and for the same hard reason as draw_admin_emails_routes above:
  # turf-monster ALREADY owns `post "/onboarding/first_name"` with the helper
  # names onboarding_first_name_path and onboarding_skip_first_name_path, so
  # drawing these unconditionally raises `Invalid route name, already in use`
  # while that app's routes.rb loads — which takes down its ENTIRE route set, not
  # just this page. Consumer CI runs each consumer's main, so a default-on flag
  # cannot be fixed from inside the engine. Each app's adoption task turns it on
  # as it deletes its local copy:
  #
  #   config.draw_onboarding_routes = true
  #
  # Gates only the ENDPOINTS. The modal partial
  # (studio/modals/onboarding/_first_name) and its /admin/style specimen are
  # always available, so a host can preview the step before it wires the writes.
  mattr_accessor :draw_onboarding_routes, default: false

  # What the onboarding endpoints report back as still-remaining after a write,
  # so the client can keep walking its chain without a second round trip.
  #
  # The engine owns ONE STEP (the first-name ask); the HOST owns the SEQUENCE
  # around it. turf-monster walks welcome → first name → age → wallet, which
  # means nothing in a hub app, so this resolver is how a host says what comes
  # next. It takes (user, session) and returns an array of step names; the
  # default — no further steps — is correct for an app whose only ask is the name.
  #
  #   config.onboarding_steps_resolver = ->(user, session) {
  #     OnboardingFlow.new(user, session).remaining.map(&:to_s)
  #   }
  mattr_accessor :onboarding_steps_resolver, default: ->(_user, _session) { [] }

  # ---- Geo (Studio::Geo, Studio::GeoSetting, Studio::GeoDetection) ---------
  #
  # An app gets geo VALIDATION — where is this visitor, render their flag, is
  # this location allowed — by including Studio::GeoDetection. It gets geo
  # LOCKING by hanging `require_geo_allowed` on the surfaces it must not serve
  # there. The engine deliberately does not decide which surfaces those are; see
  # docs/GEO.md.

  # This app's own country, ISO alpha-2. Two things read it: a bare subdivision
  # code ("WA") is resolved as a subdivision OF this country, and the fail-closed
  # rule fires only for visitors placed HERE with no detectable subdivision.
  mattr_accessor :geo_home_country, default: "US"

  # The policy a fresh app enforces before an operator has saved anything at
  # /admin/geo. Countries are alpha-2 codes; subdivisions are region tokens
  # ("US-WA"), though bare codes are accepted and normalized.
  mattr_accessor :geo_default_banned_countries, default: []
  mattr_accessor :geo_default_banned_subdivisions, default: []

  # How to treat a HOME-COUNTRY visitor whose subdivision cannot be resolved (a
  # VPN, a datacenter IP, a provider outage). true = blocked, because a blank
  # could be any of the blocked regions masked by a failed lookup. An app whose
  # geo rules are advisory rather than legal sets this false.
  mattr_accessor :geo_fail_closed, default: true

  # Freshness windows for the session-cached lookup. A RESOLVED region is trusted
  # for a day; a BLANK one is retried within minutes, so a provider blip does not
  # cache "nowhere" — and fail every gate closed — for 24 hours.
  mattr_accessor :geo_ttl, default: 24.hours
  mattr_accessor :geo_retry_ttl, default: 5.minutes

  # Where a DEVELOPMENT session stands. Loopback never geocodes, so without this
  # every geo-gated feature fails closed on a developer's own machine. Development
  # only — test and production must report an unplaceable visitor honestly.
  #
  #   config.geo_development_region = ENV.fetch("DEV_GEO_STATE", "US-CO")
  mattr_accessor :geo_development_region, default: nil

  # The region /admin/geo's "simulate" button puts the operator in, so a blocked
  # experience can be walked without a VPN. Defaults to the first blocked
  # subdivision the app actually has, which is the one worth testing.
  mattr_accessor :geo_simulated_region, default: nil

  # What a blocked visitor is told, and where an HTML request lands. The message
  # takes (subdivision, country) — both may be nil on the fail-closed path, which
  # is why the default omits an empty "( )" rather than printing one.
  mattr_accessor :geo_blocked_message, default: lambda { |subdivision, _country|
    place = subdivision.present? ? " (#{subdivision})" : ""
    "This feature is not available in your area#{place}."
  }
  mattr_accessor :geo_blocked_redirect, default: nil

  # THE OPERATOR-FACING SWITCH for the geo manager's place in the admin chrome:
  # ENABLE_GEO_BLOCKING, a plain true/false environment variable in the house
  # ENABLE_* family (ENABLE_COINFLOW, ENABLE_AGE_GATE).
  #
  # It governs the LINK AND ITS SIGNAGE, nothing else. An app with it unset still
  # detects, still blocks, still enforces — this deliberately does NOT gate the
  # gate. A default-off variable that switched enforcement would silently stop a
  # live legal blocklist on the next deploy, which is the opposite of what a
  # signpost is for.
  #
  # What it changes: the shared admin dropdown shows Geo as a DISABLED item naming
  # the variable to set, so an app that has not turned the feature on still learns
  # it exists and how to reach it — instead of the feature being invisible.
  mattr_accessor :geo_blocking_enabled, default: nil

  # nil (the default) means "read the environment"; an app that wants to decide in
  # code sets true/false in its initializer and the variable is ignored.
  def self.geo_blocking_enabled?
    return !!geo_blocking_enabled unless geo_blocking_enabled.nil?

    env_truthy?(ENV["ENABLE_GEO_BLOCKING"])
  end

  # Draw /admin/geo + /geo/check from Studio.routes. OFF by default, for the same
  # hard reason as draw_admin_emails_routes: turf-monster already owns
  # admin_geo_path, admin_geo_update_path, admin_geo_toggle_path and
  # geo_check_path, and a duplicate route NAME raises while that app's routes.rb
  # is loading — taking its entire route set down, not just this page.
  mattr_accessor :draw_geo_routes, default: false

  # Whether the engine configures Geocoder on boot (provider, HTTPS, timeout, and
  # a Rails.cache-backed IP cache). An app that configures Geocoder itself sets
  # this false; an app with no geocoder gem is unaffected either way.
  mattr_accessor :configure_geocoder, default: true
  mattr_accessor :geo_ip_provider, default: :ipinfo_io
  mattr_accessor :geo_ip_api_key, default: nil
  mattr_accessor :geo_lookup_timeout, default: 3
  mattr_accessor :geo_cache_ttl, default: 24.hours

  # Session key recording "asked, and they said not now". Session-scoped
  # DELIBERATELY: skipping means not now, not never — the field stays blank, so a
  # later session may ask again. That is the whole reason this is not a column.
  FIRST_NAME_SKIP_SESSION_KEY = :onboarding_skipped_first_name

  # How long a first name may be. ONE constant because users.first_name is
  # written from TWO surfaces — the onboarding step (seconds after signup) and
  # /profile (any time after) — and rendered by a third, the profile form's
  # maxlength. Two independently-correct caps that disagreed would let onboarding
  # accept a name /profile then refused to save, a bug with no obvious owner.
  #
  # Keeping it here rather than on either controller also keeps the VIEW off a
  # controller constant: the form needs the number, and a view reaching into
  # Studio::ProfilesController to get it would couple the two for no reason.
  FIRST_NAME_MAX_LENGTH = 40

  # The shared rule for "does this account still owe us a first name?" — the one
  # piece of onboarding logic every app agrees on. Hosts compose it into their own
  # flow rather than re-deriving it (turf's OnboardingFlow calls straight through).
  #
  # Tolerates a host whose users table has no first_name column: an app that has
  # not run the migration yet is simply never asked, instead of raising on every
  # signed-in request.
  def self.first_name_outstanding?(user, session = {})
    return false if user.blank?
    return false unless user.respond_to?(:first_name)
    return false if session.present? && session[FIRST_NAME_SKIP_SESSION_KEY]

    user.first_name.blank?
  end

  # Record a place this account has been seen from, if it is a place we have not
  # seen it from before. Returns true when something was actually written.
  #
  # NEW LOCATIONS ONLY, and that is the design rather than a shortcut: this is
  # called from the request path, so refreshing a counter on every hit would mean
  # a database write per request for no analytic gain. The first sign-in from a
  # place writes; the next thousand do not. A host wanting last-seen/count
  # refresh can call Studio::IpLocations.push directly on its own cadence.
  #
  # The host resolves the location — turf-monster already has Geocoder wired in
  # ApplicationController#detect_geo_state — and passes whatever it got. Pass
  # only an IP and the IP is what gets deduped on.
  #
  # Tolerates an app that has not run the migration (no ip_locations column):
  # it records nothing rather than raising on a request path.
  def self.record_ip_location!(user, ip:, country: nil, region: nil, city: nil, at: nil)
    return false if user.blank?
    return false unless user.respond_to?(:ip_locations)

    current = user.ip_locations
    return false if IpLocations.seen?(current, ip: ip, country: country, region: region, city: city)

    updated = IpLocations.push(current, ip: ip, country: country, region: region,
                                        city: city, at: at)
    return false if updated == IpLocations.normalize(current)

    # update_columns, not update!: analytics must never block a request, and a
    # validation failure elsewhere on the record is not this write's business.
    user.update_columns(ip_locations: updated)
    true
  end

  # Optional admin Act As / impersonation session conventions. Consumers that
  # include Studio::Impersonation get current_user layered over true_user with
  # these session keys, but still own authorization, audit logging, and routes.
  mattr_accessor :impersonation_target_session_key, default: :impersonated_user_id
  mattr_accessor :impersonation_actor_session_key,  default: :true_admin_id
  mattr_accessor :impersonation_started_at_session_key, default: :impersonation_started_at
  mattr_accessor :impersonation_max_minutes, default: 30

  # Cap for the host app's local (development + test) log file, in bytes.
  # nil means "use the engine's defaults" — Studio::Engine::DEVELOPMENT_LOG_MAX_BYTES
  # and ::TEST_LOG_MAX_BYTES. An Integer sets your own cap; `false` opts out and
  # leaves Rails' own 100 MB default alone.
  #
  # UNLIKE every other setting here, this one is read during BOOT — before
  # config/initializers/studio.rb is loaded — so it must be set earlier than the
  # usual seam: in config/application.rb (after `require "studio"`) or in
  # config/environments/development.rb. Setting it in an initializer is too late
  # and does nothing.
  mattr_accessor :local_log_max_bytes, default: nil

  # Default From: for engine-sent mail (magic links). Apps set this to their
  # verified sending address in config/initializers/studio.rb.
  mattr_accessor :mailer_from, default: nil
  mattr_accessor :resend_mailer_from, default: "McRitchie Studio <team@mcritchie.studio>"

  # Local/worktree email capture. nil means "auto": enabled when AGENT_WORKTREE
  # is truthy, otherwise disabled. Production always disables capture.
  mattr_accessor :local_email_capture, default: nil

  # The role Studio::LocalReviewsController stamps on the account it provisions
  # for a local review (the board's WAITING APPROVAL button).
  #
  # It defaults to "admin" because the pages sent for review are overwhelmingly
  # admin-gated, and the operator's address is his PRODUCTION one — an address a
  # fresh worktree database has never seen, so the sign-in would otherwise CREATE
  # him at the default role and `require_admin` would bounce him to "/". The
  # sign-in succeeds and he never sees the page: the bug this knob exists to end.
  #
  # Set it to nil (or "") to provision the account WITHOUT touching its role —
  # for an app whose review pages are not admin-gated, or whose role column
  # means something else. Only ever reached behind local_tool_enabled?
  # (non-production AND loopback), so it grants nothing a local reader could not
  # already take from the local email inbox beside it.
  mattr_accessor :local_review_role, default: "admin"

  # WHO the local-review mint signs in when the caller names no `?email=`.
  #
  # The board's WAITING APPROVAL CTA is a public, sign-in-free redirect, so it
  # sends no email — putting one in that URL would publish the operator's
  # address on a public page. The local stack answers the question instead: it
  # is the machine the reviewer is sitting at.
  #
  # nil (the default) means "derive": the first user in this database already
  # holding local_review_role, by id — falling back to "admin" when that setting
  # is itself nil. So a desk that switches local_review_role OFF has no role to
  # derive FROM and should name its operator here explicitly, as should a desk
  # whose operator is not the first seeded account at that role.
  mattr_accessor :local_review_email, default: nil

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

  # Optional key namespace INSIDE the bucket, so a satellite app can share an
  # existing bucket instead of provisioning its own pair. Set it and every key a
  # caller passes to Studio::S3 is stored/read under that prefix — callers keep
  # passing logical keys ("email_banners/magic_link-ab12.jpg") and never see it:
  #
  #   config.s3_bucket_prefix = "mcritchie-studio"
  #   config.s3_key_prefix    = "mcritchie-industries/"
  #   # -> s3://mcritchie-studio-dev/mcritchie-industries/email_banners/...
  #
  # Default nil = no namespace, so every already-shipped app's keys are unchanged.
  # A trailing slash is added if you leave it off.
  mattr_accessor :s3_key_prefix, default: nil

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

  # True when the emailed/inbox magic-link URL is the short /l/<token> — the
  # standard. False means this app draws its own token route instead and owns
  # the matching consume: turf-monster keeps /magic_link/<token> because /l is
  # already its landing-page namespace. Either way the TOKEN is the same short
  # Studio::Link token; only the path in front of it differs.
  def self.magic_link_via_l_route?
    draw_link_routes
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

  # Sidebar sections resolved for a view context: a callable config is called
  # with the view, keys symbolize, and admin-only sections drop for non-admin
  # viewers. Rendering gates on `.any?`, so [] keeps the navbar untouched.
  def self.sidebar_sections_for(view)
    SidebarSections.resolve(sidebar_sections, view)
  end

  # The engine's standard /profile rows. Hosts compose against this rather than
  # restating a literal list, so a later release that adds a standard row
  # delivers it to every app that used the seam as intended.
  def self.default_profile_sections
    ProfileSections.defaults
  end

  # Profile rows resolved for a view context: a callable config is called with
  # the view, keys symbolize, admin-only rows drop for non-admin viewers, and
  # rows this host's user model cannot serve drop entirely. `nil` config resolves
  # to the standard page.
  def self.profile_sections_for(view, page: nil)
    ProfileSections.resolve(profile_sections, view, page: page)
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

      # Passwordless email (magic link) — the REQUEST half only. Helper:
      # magic_link_request_path (POST an email address, get a link mailed).
      #
      # The token-bearing half moved to /l/<token> below (0.31.0). There is one
      # token format now — a short Studio::Link row — and one place that burns
      # it, so the old /magic_link/:token confirm+consume pair would have been a
      # second door onto the same lock.
      if Studio.draw_auth_routes && Studio.auth_method?(:magic_link)
        post "magic_link", to: "magic_links#create", as: :magic_link_request
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

      # The shared profile page. ON by default — unlike /admin/emails and the
      # onboarding pair, `profile` is claimed by no consumer, so drawing it
      # cannot take an app's route set down. See Studio.draw_profile_routes.
      #
      # Avatar is its own PATCH rather than a field on #update: an attachment
      # param submitted empty PURGES the attachment, so a single form carrying
      # both would delete someone's photo every time they edited their name.
      if Studio.draw_profile_routes
        get    "profile",        to: "studio/profiles#show",   as: :profile
        get    "profile/edit",   to: "studio/profiles#edit",   as: :edit_profile
        patch  "profile",        to: "studio/profiles#update"
        patch  "profile/avatar", to: "studio/profiles#avatar", as: :profile_avatar
        # DELETE, because unlinking removes an identity. Linking is not drawn
        # here: it is OmniAuth's own /auth/:provider, which the middleware owns.
        delete "profile/google", to: "studio/profiles#unlink_google",
               as: :profile_unlink_google

        # POST joins, DELETE leaves — the verbs the two actions actually are, on
        # one path. Not a PATCH on the profile: subscribing is its own decision
        # with its own confirmation, and folding it into the bulk field save would
        # mean every name change re-asserted a mailing-list preference.
        post   "profile/newsletter", to: "studio/profiles#subscribe_newsletter",
               as: :profile_newsletter
        delete "profile/newsletter", to: "studio/profiles#unsubscribe_newsletter"
      end

      resources :error_logs, only: [:index, :show]

      # Admin
      get   "admin/theme",            to: "theme_settings#edit",       as: :admin_theme
      patch "admin/theme",            to: "theme_settings#update",     as: :admin_theme_update
      post  "admin/theme/regenerate", to: "theme_settings#regenerate", as: :admin_theme_regenerate
      get   "admin/schema",           to: "schema#index",              as: :admin_schema

      # The shared geo manager (/admin/geo) + the public detection probe
      # (/geo/check). OPT-IN — see Studio.draw_geo_routes: turf-monster owns all
      # four of these helper names today, and drawing a name an app already has
      # raises `Invalid route name, already in use` while that app's routes.rb
      # loads, which kills every route in it. An app opts in from its initializer
      # once its local copies are deleted:
      #
      #   config.draw_geo_routes = true
      #
      # This gates only the PAGE and the probe. Detection, the badge, the policy
      # and the gate are always available to an app that includes
      # Studio::GeoDetection — an app is geo-aware whether or not it draws these.
      if Studio.draw_geo_routes
        get   "geo/check",        to: "studio/geo_settings#check",           as: :geo_check
        get   "admin/geo",        to: "studio/geo_settings#edit",            as: :admin_geo
        patch "admin/geo",        to: "studio/geo_settings#update",          as: :admin_geo_update
        post  "admin/geo/toggle", to: "studio/geo_settings#toggle_override", as: :admin_geo_toggle
      end
      # The living style guide. Canonical at /admin/style (StyleController#index);
      # /admin/design_system redirects here but KEEPS its admin_design_system_path
      # helper so a shipped host sidebar link on the old helper still resolves.
      get   "admin/style",            to: "style#index",               as: :admin_style
      get   "admin/design_system",    to: redirect("/admin/style"),    as: :admin_design_system

      # The standard transactional-email page. Canonical at /admin/emails
      # (Studio::EmailsController): index lists every registered email with its
      # live banner and whether that banner is inherited or app-owned; update
      # stores this app's own override; destroy drops it back to the inherited
      # default. Surfaced from each app's admin sidebar.
      #
      # /admin/email_images redirects here but KEEPS its admin_email_images_path
      # helper, so a shipped host sidebar link on the old helper still resolves
      # (same treatment as /admin/design_system -> /admin/style).
      # OPT-IN, and it has to be. turf-monster ALREADY owns /admin/emails —
      # `namespace :admin { get "emails", as: :emails }` (its EmailCatalog
      # manager) — which claims the SAME path and the SAME helper names,
      # admin_emails_path and admin_email_path. Drawing these unconditionally
      # raises `ArgumentError: Invalid route name, already in use: 'admin_emails'`
      # while turf-monster's own routes.rb is loading, which takes down its
      # ENTIRE route set (every admin_*_path in the app goes undefined) — not a
      # shadowed page, a dead app. Confirmed on consumer CI, PR #86.
      #
      # A host cannot opt out of something that breaks it before its config is
      # read, and consumer CI runs each consumer's `main` — so default-on cannot
      # be fixed from inside the engine. Default-off, and each app's adoption
      # task turns it on. Flip the default once no consumer's main owns the name.
      #
      # This gates only the PAGE. The registry and the two-layer image resolution
      # are always on, and the engine's own UserMailer already calls
      # Studio::EmailImage.resolved_url — so an app is branded on day one whether
      # or not it draws the page.
      if Studio.draw_admin_emails_routes
        get    "admin/emails",          to: "studio/emails#index", as: :admin_emails
        # /raw is drawn BEFORE /:key so "raw" is never captured as a key.
        get    "admin/emails/:key/raw", to: "studio/emails#raw",   as: :admin_email_raw,
               constraints: { key: /[a-z0-9_]+/ }
        get    "admin/emails/:key",     to: "studio/emails#show",  as: :admin_email,
               constraints: { key: /[a-z0-9_]+/ }
        # Same path, same helper (admin_email_path) — a named route only needs
        # to be declared once per name, and these share the show route's URL.
        patch  "admin/emails/:key",     to: "studio/emails#update",
               constraints: { key: /[a-z0-9_]+/ }
        delete "admin/emails/:key",     to: "studio/emails#destroy",
               constraints: { key: /[a-z0-9_]+/ }
        # Operator-tunable per-email settings (the banner scrim today). Separate
        # from #update, which takes an image upload.
        patch  "admin/emails/:key/settings", to: "studio/emails#settings",
               as: :admin_email_settings, constraints: { key: /[a-z0-9_]+/ }
        # The banner's words and logo. Its own route so writing a sentence and
        # nudging the tint save independently.
        patch  "admin/emails/:key/copy", to: "studio/emails#copy",
               as: :admin_email_copy, constraints: { key: /[a-z0-9_]+/ }
        # The per-email logo. Separate from the banner upload above — different
        # picture, different ImageCache purpose, independently revertible.
        patch  "admin/emails/:key/logo", to: "studio/emails#logo",
               as: :admin_email_logo, constraints: { key: /[a-z0-9_]+/ }
      end

      # The shared first-name onboarding step's two writes. OPT-IN — see
      # Studio.draw_onboarding_routes above: turf-monster owns these exact helper
      # names today, and drawing them there before its adoption task deletes the
      # local pair kills every route in that app.
      #
      # The paths match the partial's defaults, so a host that opts in and has no
      # other onboarding of its own needs no further wiring.
      if Studio.draw_onboarding_routes
        post "onboarding/first_name",      to: "studio/onboarding#first_name",
             as: :onboarding_first_name
        post "onboarding/skip_first_name", to: "studio/onboarding#skip_first_name",
             as: :onboarding_skip_first_name
      end

      # DEPRECATED, kept for ONE release. Not a redirect: consumer-ci.yml runs
      # each consumer's DEFAULT-BRANCH suite against this engine, and both
      # mcritchie-studio and turf-monster have tests on `main` that GET this page
      # and PATCH through admin_email_image_path. Redirecting (or deleting) here
      # reddens their lanes the moment the PR opens, and no change inside the
      # engine PR can fix it. Each app's adoption task moves its link + tests; a
      # later engine minor deletes these two routes with the controller and view.
      get   "admin/email_images",          to: "studio/email_images#index",  as: :admin_email_images
      patch "admin/email_images/:variant", to: "studio/email_images#update", as: :admin_email_image,
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
