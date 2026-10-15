# frozen_string_literal: true

require_relative "environment_banner"

module Studio
  # OBJECT STORAGE IS CLOUDFLARE R2, AND ONLY R2. One copy of the rules the hub,
  # turf-monster and mcritchie-industries each carried as a hand-written
  # `StorageBackend` module (AWS S3 was retired on 2026-10-10, so there is no S3
  # stage and no mirror stage left to select). README.md, "Managed storage".
  #
  # ON BY DEFAULT for every app that names its bucket (`config.s3_bucket_prefix`).
  # Such an app gets, with no initializer of its own:
  #
  #   - the BOOT CHECK (Studio::Engine, "studio.storage"): a retired or unknown
  #     switch value, or a missing R2 variable in production, refuses the boot
  #     by name. config/storage.yml is rendered lazily (a release-phase
  #     db:migrate never renders it), so without a boot check a bad value passes
  #     the release and crash-loops web and worker instead.
  #   - Studio::S3 on R2: endpoint, region "auto", keys and public URL, filled in
  #     when the app left `s3_endpoint` unset (an app that hand-configures the
  #     connection keeps it; the engine stands back).
  #   - Active Storage services `amazon` (this environment's bucket) and
  #     `amazon_dev` (always the dev bucket), both `service: StudioTrashS3` on R2.
  #     The names are kept because blob rows record them. A service of the same
  #     name in the app's own config/storage.yml WINS, so an app's own copy keeps
  #     working until it adopts this one.
  #
  # Opt out with `config.manage_storage = false`.
  #
  # THE TWO SWITCHES, ACTIVE_STORAGE_BACKEND and STUDIO_S3_BACKEND, staged the
  # move and are still `r2` on the deployed apps. Unset or `r2` means R2. A
  # retired value (s3, mirror_to_r2, mirror_to_s3) or any other value RAISES in
  # every environment: it must never look like a successful selection of a store
  # that no longer exists.
  #
  # THE CONNECTION: R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY (1Password
  # item r2.<prefix>: the prod pair on production, the dev pair on QA and
  # locally), plus R2_PUBLIC_URL, which is required only when the app sets
  # `config.storage_public_url_required = true` (it serves public object URLs to
  # strangers; an app with private objects only has no public domain).
  #
  # A MISSING VARIABLE:
  #   production (QA boots RAILS_ENV=production too)   RAISES, naming every
  #     missing variable. A dyno that boots without storage fails at the first
  #     upload hours later; one that refuses to boot fails the deploy.
  #   elsewhere, NONE set (test, CI, a keyless desk)   boots on a placeholder
  #     connection: a reserved `.invalid` host (RFC 2606, never resolves) and
  #     placeholder keys, so nothing reaches AWS through the SDK's default
  #     endpoint or credential chain, and the first real call fails naming
  #     r2-not-configured.invalid.
  #   elsewhere, SOME set   RAISES, naming the missing ones: half a configuration
  #     is a mistake, not a choice.
  #
  # Dependency-free apart from EnvironmentBanner, so the unit suite requires it
  # directly and every method takes its inputs as arguments.
  module Storage
    BACKEND = "r2"
    SWITCHES = %w[ACTIVE_STORAGE_BACKEND STUDIO_S3_BACKEND].freeze
    RETIRED_VALUES = %w[s3 mirror_to_r2 mirror_to_s3].freeze

    CONNECTION_VARIABLES = %w[R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY].freeze
    PUBLIC_URL_VARIABLE = "R2_PUBLIC_URL"
    REGION = "auto"

    # The engine's Active Storage service: S3Service whose delete MOVES the
    # object under trash/<utc date>/<epoch ms>/<key>, so a purged or replaced
    # attachment has a three-day grace period
    # (lib/active_storage/service/studio_trash_s3_service.rb).
    ACTIVE_STORAGE_SERVICE = "StudioTrashS3"
    # The service names blob rows record. `amazon` is this environment's bucket;
    # `amazon_dev` is the dev bucket in every environment (local desks).
    SERVICE = "amazon"
    DEV_SERVICE = "amazon_dev"

    UNCONFIGURED_HOST = "r2-not-configured.invalid"
    PLACEHOLDER_ENDPOINT = "https://#{UNCONFIGURED_HOST}"
    PLACEHOLDER_KEY = "r2-not-configured"
    PLACEHOLDER_PUBLIC_URL = "https://#{UNCONFIGURED_HOST}"

    module_function

    # Whether the engine manages this app's storage: it named its bucket and did
    # not opt out.
    def enabled?(prefix: Studio.s3_bucket_prefix, manage: manage_setting)
      manage != false && !prefix.to_s.strip.empty?
    end

    # Whether a missing R2 variable refuses the boot. Production and QA both run
    # RAILS_ENV=production.
    def strict?
      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.respond_to?(:production?) && Rails.env.production? ? true : false
    end

    def active_storage_stage(env = ENV)
      stage(env, "ACTIVE_STORAGE_BACKEND")
    end

    def studio_s3_stage(env = ENV)
      stage(env, "STUDIO_S3_BACKEND")
    end

    def stage(env, name)
      value = env[name].to_s.strip
      return BACKEND if value.empty? || value == BACKEND

      if RETIRED_VALUES.include?(value)
        raise ArgumentError, "#{name}=#{value.inspect} names a retired stage: AWS S3 was retired on 2026-10-10 " \
                             "and storage runs on Cloudflare R2 only. Unset #{name} or set it to #{BACKEND}."
      end

      raise ArgumentError, "#{name}=#{value.inspect} is not a storage backend; unset #{name} or set it to #{BACKEND}"
    end

    # The variables a complete connection needs.
    def variables(public_url_required: public_url_required_setting)
      public_url_required ? CONNECTION_VARIABLES + [PUBLIC_URL_VARIABLE] : CONNECTION_VARIABLES
    end

    # Whether this process holds a real R2 connection: every required variable
    # set. False on CI and a keyless desk, where the connection is placeholders;
    # code that must refuse up front rather than fail at its first call asks
    # this, because the placeholder keys make "is a key set?" answer yes.
    def configured?(env = ENV, public_url_required: public_url_required_setting)
      variables(public_url_required: public_url_required).all? { |name| present?(env, name) }
    end

    # Whether development should talk to the remote dev bucket rather than Disk:
    # whenever any R2 variable is set at all (a laptop's .env.development).
    def remote_in_development?(env = ENV)
      (CONNECTION_VARIABLES + [PUBLIC_URL_VARIABLE]).any? { |name| present?(env, name) }
    end

    # The R2 connection: { endpoint:, access_key_id:, secret_access_key:,
    # public_url: }. public_url is nil when R2_PUBLIC_URL is unset and not
    # required. See the module comment for what a missing variable does.
    def connection(env = ENV, strict: strict?, public_url_required: public_url_required_setting,
                   prefix: Studio.s3_bucket_prefix)
      names = variables(public_url_required: public_url_required)
      missing = names.reject { |name| present?(env, name) }

      if missing.empty?
        return { endpoint: value(env, "R2_ENDPOINT"), access_key_id: value(env, "R2_ACCESS_KEY_ID"),
                 secret_access_key: value(env, "R2_SECRET_ACCESS_KEY"),
                 public_url: present?(env, PUBLIC_URL_VARIABLE) ? value(env, PUBLIC_URL_VARIABLE) : nil }
      end

      if !strict && missing.size == names.size
        return { endpoint: PLACEHOLDER_ENDPOINT, access_key_id: PLACEHOLDER_KEY, secret_access_key: PLACEHOLDER_KEY,
                 public_url: public_url_required ? PLACEHOLDER_PUBLIC_URL : nil }
      end

      why = if strict
              "production and QA refuse to boot without it"
            else
              "#{(names - missing).join(', ')} #{names.size - missing.size == 1 ? 'is' : 'are'} set, and half a " \
                "configuration is a mistake: set all of #{names.join(', ')} or none"
            end
      raise ArgumentError, "#{missing.join(', ')} must be set: storage runs on Cloudflare R2 only, and #{why} " \
                           "(#{credential_source(prefix)})"
    end

    # The credentials an operator should check when Studio::S3 fails wholesale.
    def credential_hint(public_url_required: public_url_required_setting)
      "#{variables(public_url_required: public_url_required).join(' / ')} (local dev reads them from .env.development)"
    end

    # The Studio.configure settings for Studio::S3. s3_public_url is present only
    # when there is one to give (see #connection).
    def studio_s3_settings(env = ENV, strict: strict?, public_url_required: public_url_required_setting,
                           prefix: Studio.s3_bucket_prefix)
      studio_s3_stage(env)
      r2 = connection(env, strict: strict, public_url_required: public_url_required, prefix: prefix)
      settings = { s3_endpoint: r2[:endpoint], s3_region: REGION,
                   s3_access_key_id: r2[:access_key_id], s3_secret_access_key: r2[:secret_access_key] }
      settings[:s3_public_url] = r2[:public_url] if r2[:public_url]
      settings
    end

    # WHICH BUCKET. Only real production gets "<prefix>-production". QA boots
    # RAILS_ENV=production exactly like production, so QA_ENV
    # (Studio.qa_environment?) is what sends it to "<prefix>-dev", the same
    # resolution Studio::S3 picks its bucket by, which keeps both writers on one
    # bucket. A laptop, a desk and CI resolve the dev bucket too.
    def bucket(prefix = Studio.s3_bucket_prefix, production: production_environment?)
      "#{require_prefix(prefix)}-#{production ? 'production' : 'dev'}"
    end

    def dev_bucket(prefix = Studio.s3_bucket_prefix)
      bucket(prefix, production: false)
    end

    # Real production: Rails production and not a QA app.
    def production_environment?(env = ENV)
      strict? && !EnvironmentBanner.qa_environment?(env)
    end

    # One Active Storage service config on R2. Checksums only when required:
    # Active Storage sends Content-MD5, aws-sdk-s3 >= 1.178 adds a CRC32 by
    # default, and R2 refuses a request carrying both (measured 2026-09-28).
    def service(bucket_name, r2)
      { "service" => ACTIVE_STORAGE_SERVICE,
        "endpoint" => r2.fetch(:endpoint), "access_key_id" => r2.fetch(:access_key_id),
        "secret_access_key" => r2.fetch(:secret_access_key),
        "region" => REGION, "bucket" => bucket_name,
        "request_checksum_calculation" => "when_required",
        "response_checksum_validation" => "when_required" }
    end

    # The services the engine supplies: { "amazon" => ..., "amazon_dev" => ... }.
    def active_storage_services(env = ENV, prefix: Studio.s3_bucket_prefix, strict: strict?,
                                production: production_environment?(env))
      active_storage_stage(env)
      r2 = connection(env, strict: strict, public_url_required: false, prefix: prefix)
      { SERVICE => service(bucket(prefix, production: production), r2),
        DEV_SERVICE => service(dev_bucket(prefix), r2) }
    end

    # The app's own service configurations with the engine's merged UNDER them:
    # a name the app's storage.yml already defines keeps the app's definition.
    # Computes nothing (and so raises nothing) when the app defines both.
    def merge_services(existing, env = ENV, prefix: Studio.s3_bucket_prefix, strict: strict?,
                       production: production_environment?(env))
      existing = (existing || {}).to_h
      defined = existing.keys.map(&:to_s)
      return existing if [SERVICE, DEV_SERVICE].all? { |name| defined.include?(name) }

      supplied = active_storage_services(env, prefix: prefix, strict: strict, production: production)
      supplied.reject { |name, _| defined.include?(name) }.merge(existing)
    end

    # What Active Storage itself would read when the app sets no
    # service_configurations: config/storage/<env>.yml, else config/storage.yml.
    # An app with neither starts from no services, and gets the engine's.
    def storage_file_configurations(root, rails_env)
      file = File.join(root.to_s, "config/storage/#{rails_env}.yml")
      file = File.join(root.to_s, "config/storage.yml") unless File.exist?(file)
      return {} unless File.exist?(file)

      require "active_support/configuration_file"
      ActiveSupport::ConfigurationFile.parse(file) || {}
    end

    # Point Studio::S3 at R2, unless the app configured the connection itself
    # (s3_endpoint already set). A public URL the app set is never overwritten.
    # Returns whether it wrote anything.
    def apply_studio_s3_settings!(config = Studio, env = ENV, strict: strict?,
                                  public_url_required: public_url_required_setting)
      return false unless config.s3_endpoint.to_s.strip.empty?

      settings = studio_s3_settings(env, strict: strict, public_url_required: public_url_required,
                                         prefix: config.s3_bucket_prefix)
      settings.delete(:s3_public_url) unless config.s3_public_url.to_s.strip.empty?
      settings.each { |name, setting| config.public_send("#{name}=", setting) }
      true
    end

    # THE BOOT CHECK. Both switches, always. The connection, when the engine
    # owns it (the app left s3_endpoint unset); an app still carrying its own
    # copy checks its own.
    def validate!(env = ENV, strict: strict?, public_url_required: public_url_required_setting,
                  prefix: Studio.s3_bucket_prefix, check_connection: true)
      active_storage_stage(env)
      studio_s3_stage(env)
      connection(env, strict: strict, public_url_required: public_url_required, prefix: prefix) if check_connection
      true
    end

    def credential_source(prefix)
      name = prefix.to_s.strip
      name.empty? ? "1Password item r2.<app>" : "1Password item r2.#{name}"
    end

    def present?(env, name)
      !value(env, name).empty?
    end

    def value(env, name)
      env[name].to_s.strip
    end

    def require_prefix(prefix)
      name = prefix.to_s.strip
      raise ArgumentError, "Studio.s3_bucket_prefix not set in config/initializers/studio.rb" if name.empty?

      name
    end

    def manage_setting
      Studio.respond_to?(:manage_storage) ? Studio.manage_storage : true
    end

    def public_url_required_setting
      Studio.respond_to?(:storage_public_url_required) ? Studio.storage_public_url_required : false
    end
  end
end
