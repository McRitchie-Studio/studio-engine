module Studio
  # The transactional-email registry, and the banner image each registered email
  # ships with.
  #
  # A registered email is MOSTLY SYMBOLIC of a workflow — a key, a human label,
  # a line of description. The only real asset is its banner image, which is why
  # the registry lives here rather than in a model. The branded mailer resolves
  # the live banner with .url; /admin/emails lists the registry and writes an
  # override with .store.
  #
  # ## Two layers: inherited default, app-owned override
  #
  #   .url(key) => app's own ImageCache row (its S3 bucket)   # app-owned
  #             -> the engine's default gem asset             # inherited
  #             -> nil                                        # no image at all
  #
  # Defaults RIDE THE GEM (app/assets/images/emails/*), so a brand-new app with
  # an empty bucket sends good-looking email on day one and needs no cross-app S3
  # permission. Uploading on an app's /admin/emails writes to THAT app's bucket
  # and THAT app's ImageCache row — which is exactly "the asset now belongs to
  # this app". Every app has its own bucket and its own image_caches table, so an
  # override never leaks between apps.
  #
  # ## Registering
  #
  # The engine pre-registers the two every Studio app sends (STANDARD below), so
  # hosts inherit them without declaring anything. A host adds its own workflows
  # from an initializer, mirroring Studio::ModelPage.register:
  #
  #   # config/initializers/studio_emails.rb
  #   Rails.application.config.to_prepare do
  #     Studio::EmailImage.register("winnings", label: "Contest winnings",
  #                                 description: "Sent when a player wins a contest.")
  #   end
  #
  # Re-registering a key updates it in place and keeps its position, so a host
  # can relabel an inherited email without reordering the page.
  module EmailImage
    PURPOSE = "email_banner".freeze

    # A registered email. `default_asset` is a logical asset path inside the gem
    # (resolved through the host's asset pipeline); nil means the email has no
    # inherited artwork and renders bannerless until someone uploads one.
    Entry = Struct.new(:key, :label, :description, :default_asset, keyword_init: true) do
      def to_s = key
    end

    # The emails EVERY Studio app sends. Pre-registered, so a host inherits both
    # without declaring anything.
    STANDARD = [
      {
        key: "magic_link",
        label: "Magic-link sign-in",
        description: "Passwordless sign-in link. Sent whenever someone asks to sign in by email.",
        default_asset: "emails/magic-link.png"
      },
      {
        key: "email_change_confirmation",
        label: "Email change confirmation",
        description: "Confirms a new address before the change takes effect.",
        default_asset: "emails/email-change-confirmation.png"
      }
    ].freeze

    # Banners render full-bleed at 600px in a 600px card. 1200x600 is the
    # right cut: 2:1, retina-sharp at render width, and small enough to stay
    # out of an inbox clipping limit.
    ASPECT_RATIO = 2.0
    MAX_WIDTH = 1200

    module_function

    # --- Registry ----------------------------------------------------------

    # Register (or update) an email workflow. Returns the key.
    def register(key, label: nil, description: nil, default_asset: nil)
      key = key.to_s
      existing = registry[key]
      registry[key] = Entry.new(
        key: key,
        label: label || existing&.label || key.humanize,
        description: description || existing&.description,
        default_asset: default_asset.nil? ? existing&.default_asset : default_asset.presence
      )
      key
    end

    # Every registered email, in display order: the standard two first, then the
    # host's own in declaration order.
    def entries
      registry.values
    end

    def entry(key)
      registry[key.to_s]
    end

    def keys
      registry.keys
    end

    def known?(key)
      registry.key?(key.to_s)
    end
    def registered?(key) = known?(key)

    def label(key)
      entry(key)&.label || key.to_s.humanize
    end

    # Legacy shape — key => label. Kept because it is the API the pre-registry
    # admin page and any host that read VARIANTS were written against.
    def variants
      registry.transform_values(&:label)
    end

    # Drops host registrations back to the standard two. For tests and for
    # to_prepare re-registration.
    def reset!
      @registry = nil
      registry
      nil
    end

    def registry
      @registry ||= STANDARD.each_with_object({}) do |attrs, out|
        out[attrs[:key]] = Entry.new(**attrs)
      end
    end

    # --- Resolution --------------------------------------------------------

    # Where the live banner for this email comes from:
    #   :app     — this app uploaded its own (ImageCache row in its bucket)
    #   :default — the inherited engine default (gem asset)
    #   :none    — no image at all; the email sends bannerless
    def source(key)
      return :app if record(key)
      return :default if default_asset_path(key)

      :none
    end

    def app_owned?(key) = source(key) == :app

    # The URL a MAILER should use — absolute, so it resolves from an inbox.
    # App-owned override first, then the inherited default, then nil.
    def url(key)
      override_url(key) || default_url(key)
    end

    # The URL the ADMIN PAGE should preview. Same resolution, but a default
    # stays a root-relative asset path so it renders correctly whatever host and
    # port this app is being viewed on (an absolute mailer asset_host is set for
    # the inbox, not for the browser sitting on localhost:3042).
    def preview_url(key)
      override_url(key) || default_asset_path(key)
    end

    # The app-owned override only (nil when this app has not uploaded one).
    def override_url(key)
      record(key)&.url
    end

    # The ImageCache row holding this app's override, or nil (nothing uploaded /
    # table not installed yet). Nil-safe so the mailer renders before any upload.
    def record(key)
      return nil unless table_ready?

      ::ImageCache.find_by(owner: nil, purpose: PURPOSE, variant: key.to_s)
    end

    # Root-relative path to the inherited default asset, or nil when the email
    # has no default registered or the host's pipeline cannot resolve it.
    def default_asset_path(key)
      asset = entry(key)&.default_asset
      return nil if asset.nil? || asset.empty?

      path = ActionController::Base.helpers.asset_path(asset)
      path.presence
    rescue StandardError
      nil
    end

    # Absolute URL to the inherited default asset — what a mailer needs. Uses
    # action_mailer.asset_host (set per env), falling back to the mailer's
    # default_url_options host. Returns the bare path if neither is configured,
    # which still renders in the local inbox preview.
    def default_url(key)
      path = default_asset_path(key)
      return nil if path.nil?
      return path if path.start_with?("http")

      host = mailer_asset_host
      host ? "#{host}#{path}" : path
    end

    # --- Upload ------------------------------------------------------------

    # Whether THIS app can accept an upload. False when the host never set
    # Studio.s3_bucket_prefix — /admin/emails then shows inherited defaults
    # read-only rather than 500ing on the first upload.
    def uploads_available?
      Studio::S3.configured? && table_ready?
    end

    # Upload bytes to this app's bucket + upsert its ImageCache row (replacing
    # any prior object). Returns the ::ImageCache. Raises on failure after
    # cleaning up the new object.
    def store(key, io:, content_type: nil)
      s3_key = "email_banners/#{key}-#{SecureRandom.hex(4)}#{ext_for(content_type)}"
      Studio::S3.upload(key: s3_key, body: io.read, content_type: content_type,
                        cache_control: "public, max-age=300")
      record = ::ImageCache.find_or_initialize_by(owner: nil, purpose: PURPOSE, variant: key.to_s)
      previous = record.s3_key
      record.update!(s3_key: s3_key)
      delete_object(previous) if previous.present? && previous != s3_key
      record
    rescue StandardError
      delete_object(s3_key)
      raise
    end

    # Drop this app's override and fall back to the inherited default. Returns
    # true when a row was removed.
    def revert(key)
      row = record(key)
      return false if row.nil?

      previous = row.s3_key
      row.destroy!
      delete_object(previous) if previous.present?
      true
    end

    # --- Internals ---------------------------------------------------------

    # Reference ImageCache directly so Zeitwerk autoloads it — defined?() does NOT
    # trigger autoload, so it would read "undefined" for a not-yet-loaded const.
    def table_ready?
      ::ImageCache.table_exists?
    rescue NameError, ActiveRecord::ActiveRecordError
      false
    end

    def mailer_asset_host
      host = Rails.application.config.action_mailer.asset_host.presence
      return host if host

      host = ActionMailer::Base.default_url_options[:host]
      return nil if host.blank?

      host.start_with?("http") ? host : "https://#{host}"
    rescue StandardError
      nil
    end

    def ext_for(content_type)
      case content_type.to_s
      when %r{png}    then ".png"
      when %r{jpe?g}  then ".jpg"
      when %r{webp}   then ".webp"
      else ".png"
      end
    end

    def delete_object(key)
      Studio::S3.delete(key: key)
    rescue StandardError
      nil
    end
  end
end
