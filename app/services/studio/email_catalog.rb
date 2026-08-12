module Studio
  # The shared email catalog: every email an app sends, what kind it is, how to
  # build a live preview of it, and the banner image it ships with.
  #
  # Named for the prior art it absorbs. turf-monster built ::EmailCatalog +
  # Admin::EmailsController first and left a note on both saying this manager
  # "moves into the shared studio-engine email framework (Phase 2)". This is
  # Phase 2 — so the engine takes the name, the shape (key / name / type /
  # description / preview builder), and the live-preview page, and adds the
  # banner-image half. turf-monster then deletes its copy instead of running two
  # email pages side by side.
  #
  # Was Studio::EmailImage, which is now a delegating shim — see
  # app/services/studio/email_image.rb. The old name outlived its meaning the
  # moment an entry carried a type and a preview builder alongside its image.
  #
  # ## Two layers: inherited default, app-owned override
  #
  #   .resolved_url(key) => app's own ImageCache row (its S3 bucket)  # app-owned
  #                      -> the engine's default gem asset            # inherited
  #                      -> nil                                       # no image
  #
  # `.url(key)` stays the PRE-REGISTRY contract — this app's own image or nil —
  # so every caller written before the registry keeps its behavior until its app
  # adopts. See the note on #url; getting this wrong swaps a host's committed
  # artwork for the engine placeholder in live email.
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
  #     Studio::EmailCatalog.register("winnings",
  #       label: "Contest winnings",
  #       description: "Sent when a player wins a contest.",
  #       type: :transactional,
  #       preview: -> { ContestMailer.winnings(Entry.where.not(rank: nil).first) })
  #   end
  #
  # Re-registering a key updates it in place and keeps its position, so a host
  # can relabel an inherited email without reordering the page.
  #
  # ## Preview
  #
  # `preview` is a callable returning a Mail — the app builds it from whatever
  # sample data it likes. It is what powers the live preview on /admin/emails/:key.
  # It runs ONLY on that admin page, never in a delivery path, and every call is
  # wrapped: an entry whose builder raises shows the error on the page rather
  # than 500ing the manager. An entry without one still lists and still manages
  # its banner; it just has nothing to preview.
  module EmailCatalog
    PURPOSE = "email_banner".freeze

    # What an email is FOR. Transactional = sent in response to something the
    # recipient did; marketing = sent because we decided to. Kept because
    # turf-monster's catalog carried it and the distinction drives real policy
    # (unsubscribe requirements, send-time rules, which from-address is used).
    TYPES = %i[transactional marketing].freeze
    DEFAULT_TYPE = :transactional

    # A registered email.
    #   default_asset — logical asset path inside the gem (resolved through the
    #                   host's pipeline); nil means no inherited artwork.
    #   type          — :transactional or :marketing.
    #   preview       — callable returning a Mail, or nil.
    Entry = Struct.new(:key, :label, :description, :default_asset, :type, :preview,
                       :default_origin, :aspect_ratio, :background, :logo, :scrim,
                       keyword_init: true) do
      def to_s = key
      def previewable? = preview.respond_to?(:call)
      # nil-safe: an Entry built directly (the STANDARD seed) may carry no type.
      def marketing? = type.to_s == "marketing"

      # WHOSE artwork default_asset names. Recorded at registration rather than
      # inferred later: by the time the page asks, a resolved asset path looks
      # identical whether the file came from the gem or from the host, and
      # guessing from the path is exactly the wrong-answer machine this exists
      # to remove. The engine seeds its own two as :engine; anything a host
      # passes default_asset for is that host's own.
      def engine_artwork? = default_origin.to_s != "app"

      # The shape of THIS email's banner — the box the page draws and the ratio
      # the upload cropper enforces. Per-entry because the engine's own artwork
      # is 3:1 while turf-monster's eight banners are 2:1; one global constant
      # would letterbox one app's art and crop the other's on every upload.
      def ratio = (aspect_ratio || ASPECT_RATIO).to_f
    end

    # The emails EVERY Studio app sends. Pre-registered, so a host inherits both
    # without declaring anything.
    STANDARD = [
      {
        key: "magic_link",
        label: "Magic-link sign-in",
        description: "Passwordless sign-in link. Sent whenever someone asks to sign in by email.",
        default_asset: "emails/magic-link.gif",
        aspect_ratio: 3.0,
        # Layered artwork: the background animates, the greeting is live HTML on
        # top. default_asset above stays the flat <img> for a mailer that has not
        # adopted the layered banner.
        background: "emails/magic-link-background.gif",
        logo: "emails/logo-horizontal.png"
      },
      {
        key: "email_change_confirmation",
        label: "Email change confirmation",
        description: "Confirms a new address before the change takes effect.",
        default_asset: "emails/email-change-confirmation.gif",
        aspect_ratio: 3.0
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
    #
    # Every keyword is OPTIONAL and omitting one on a re-register KEEPS the
    # existing value — that is what lets a host relabel an inherited email, or
    # attach a preview builder to it, without restating its artwork.
    def register(key, label: nil, description: nil, default_asset: nil, type: nil, preview: nil,
                 aspect_ratio: nil, background: nil, logo: nil, scrim: nil)
      key = key.to_s
      existing = registry[key]
      registry[key] = Entry.new(
        key: key,
        label: label || existing&.label || key.humanize,
        description: description || existing&.description,
        default_asset: default_asset.nil? ? existing&.default_asset : default_asset.presence,
        type: normalize_type(type || existing&.type),
        preview: preview || existing&.preview,
        # Passing artwork here makes it THIS APP's artwork — that is the only
        # moment anyone can know. Omitting it keeps whatever the entry already
        # had, so a host relabelling an inherited email does not accidentally
        # claim the engine's picture as its own.
        default_origin: default_asset.nil? ? (existing&.default_origin || :engine) : :app,
        aspect_ratio: aspect_ratio || existing&.aspect_ratio,
        background: background.nil? ? existing&.background : background.presence,
        logo: logo.nil? ? existing&.logo : logo.presence,
        scrim: scrim.nil? ? existing&.scrim : scrim
      )
      key
    end

    # Unknown types fall back to :transactional rather than raising — a typo in
    # an initializer must not take the host's boot down over a display label.
    def normalize_type(type)
      symbol = type.to_s.strip.downcase.to_sym
      TYPES.include?(symbol) ? symbol : DEFAULT_TYPE
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
      @preview_errors = nil
      registry
      nil
    end

    # Seeded through the SAME normalization register() uses, so a standard entry
    # is indistinguishable from a host-registered one (its `type` is a real
    # symbol, not nil) and every reader can trust the shape.
    def registry
      @registry ||= STANDARD.each_with_object({}) do |attrs, out|
        out[attrs[:key]] = Entry.new(**attrs, type: normalize_type(attrs[:type]),
                                     preview: attrs[:preview], default_origin: :engine,
                                     aspect_ratio: attrs[:aspect_ratio],
                                     background: attrs[:background], logo: attrs[:logo],
                                     scrim: attrs[:scrim])
      end
    end

    # --- Resolution --------------------------------------------------------

    # Where the live banner for this email actually comes from:
    #
    #   :app            — uploaded on this app's /admin/emails (ImageCache row
    #                     in this app's bucket). Revertible.
    #   :app_asset      — registered by this app, committed in its own repo.
    #   :engine_default — the shared artwork that ships in the gem.
    #   :none           — no image at all; the email sends bannerless.
    #
    # `:default` USED to cover the middle two together, and the page said
    # "Shared Studio artwork, shipped with the engine" for both — so
    # turf-monster's own eight banners were announced as the engine's. Telling
    # the operator the wrong provenance is the same failure this page was built
    # to end (the page it replaced claimed "No image yet" about an email that
    # was visibly sending one).
    #
    # `:app` is deliberately unchanged: turf-monster's suite on `main` asserts
    # it, and consumer CI runs consumers' default branch.
    def source(key)
      return :app if record(key)
      return :none unless default_asset_path(key)

      entry(key)&.engine_artwork? ? :engine_default : :app_asset
    end

    # True when the live banner belongs to this app either way — uploaded here
    # or committed here. What the page's summary line counts.
    def app_artwork?(key) = %i[app app_asset].include?(source(key))

    # This email's banner shape, falling back to the shared default.
    def ratio(key) = entry(key)&.ratio || ASPECT_RATIO

    # --- layered banner artwork ---------------------------------------------
    #
    # Absolute URLs, because a mail client fetches these from an inbox and a
    # root-relative path resolves against nothing there.

    def background_url(key) = absolute_asset_url(entry(key)&.background)
    def logo_url(key)       = absolute_asset_url(entry(key)&.logo)

    def absolute_asset_url(asset)
      return nil if asset.blank?

      path = ActionController::Base.helpers.asset_path(asset)
      return nil if path.blank?
      return path if path.start_with?("http")

      host = mailer_asset_host
      host ? "#{host}#{path}" : path
    rescue StandardError
      nil
    end

    def app_owned?(key) = source(key) == :app

    # --- Preview -----------------------------------------------------------

    def previewable?(key)
      entry(key)&.previewable? || false
    end

    def type(key)
      entry(key)&.type || DEFAULT_TYPE
    end

    # Build the sample Mail for this email, or nil.
    #
    # NEVER raises. A preview builder is host code running against whatever
    # sample data happens to be in this environment — an empty table, a fixture
    # that moved, a mailer whose signature changed. Any of those must show up as
    # a message ON the preview page, not as a 500 that takes the whole email
    # manager down with it. Returns nil; ask #preview_error for the reason.
    def preview_mail(key)
      callable = entry(key)&.preview
      return nil unless callable.respond_to?(:call)

      @preview_errors ||= {}
      @preview_errors.delete(key.to_s)
      force_message(callable.call)
    rescue StandardError, ScriptError => e
      (@preview_errors ||= {})[key.to_s] = "#{e.class}: #{e.message}"
      nil
    end

    # The reason the last preview_mail(key) returned nil, or nil if it did not
    # fail. Set by preview_mail; read by the page so it can say WHY.
    def preview_error(key)
      (@preview_errors ||= {})[key.to_s]
    end

    # The rendered HTML body of the preview, for the iframe. nil when the email
    # has no builder or the builder failed.
    def preview_html(key)
      mail = preview_mail(key)
      return nil if mail.nil?

      (mail.html_part&.body || mail.body).to_s
    rescue StandardError => e
      (@preview_errors ||= {})[key.to_s] = "#{e.class}: #{e.message}"
      nil
    end

    def preview_subject(key)
      preview_mail(key)&.subject
    end

    # Force a builder's return value to a REAL mail, here, inside preview_mail's
    # rescue.
    #
    # The documented idiom — `preview: -> { UserMailer.magic_link(user, token) }`
    # — does not return a Mail. It returns an ActionMailer::MessageDelivery, a
    # LAZY proxy: the mailer action has not run yet, and the first call to
    # `subject` / `html_part` is what finally runs it. So without this, a builder
    # that fails takes `callable.call` cleanly, records NO error, and then blows
    # up later at `preview_subject` — outside every rescue, straight into the
    # host's error handler, taking the whole page down. That is the exact failure
    # this class exists to prevent, so the forcing belongs at the same layer as
    # the rescue, not at each call site.
    #
    # Duck-typed rather than `is_a?(ActionMailer::MessageDelivery)`: it also
    # covers Parameterized::MessageDelivery and any host's own lazy wrapper.
    # Mail::Message does NOT respond to `message`, so a builder that already
    # returns a real Mail passes straight through.
    def force_message(result)
      result.respond_to?(:message) ? result.message : result
    end
    private_class_method :force_message

    # THIS APP'S OWN image only — nil when nothing has been uploaded here.
    #
    # This is the PRE-REGISTRY contract, kept EXACTLY: `url` has always meant
    # "the admin-managed override, or nil", and callers were written to fall back
    # themselves. turf-monster's mailer is the live example:
    #
    #   @banner_url = Studio::EmailImage.url(:magic_link) || email_banner_url("magic-link-banner.jpg")
    #
    # Making `url` resolve to the engine default would make that `||` dead code
    # and silently replace turf-monster's own branded 1200x600 banner with the
    # engine's PLACEHOLDER in real sign-in email. A method whose signature is
    # unchanged but whose return value flips from nil to a value is not additive.
    # So the new two-layer resolution lives in resolved_url, and every existing
    # caller keeps the behavior it was written against until its app adopts.
    def url(key)
      record(key)&.url
    end

    # What ACTUALLY SHIPS on this email — the two-layer resolution. Absolute, so
    # it resolves from an inbox. App-owned override first, then the inherited
    # engine default, then nil (the mailer renders bannerless).
    #
    # This is what a mailer should call once its app has adopted the registry.
    # The engine's own UserMailer already does, which is what gives an app with
    # an empty bucket branded email on day one.
    def resolved_url(key)
      url(key) || default_url(key)
    end

    # What the ADMIN PAGE previews. Same two layers as resolved_url, but a
    # default stays a root-relative asset path so it renders correctly on
    # whatever host and port this app is being viewed on (an absolute mailer
    # asset_host is set for the inbox, not for a browser on localhost:3042).
    def preview_url(key)
      url(key) || default_asset_path(key)
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

    # The origin an email's banner URL hangs off. action_mailer.asset_host when
    # the host sets one (turf-monster does, per env); otherwise built from the
    # mailer's default_url_options.
    #
    # That fallback has to reconstruct a real origin, not just the hostname.
    # default_url_options is routinely {host: "localhost", port: 3001} — taking
    # :host alone and prefixing "https://" yields https://localhost, which is the
    # wrong scheme AND the wrong port, and the banner comes back
    # ERR_CONNECTION_REFUSED. Caught by opening the preview page on a worktree
    # stack; every dev/QA preview took that path.
    def mailer_asset_host
      configured = Rails.application.config.action_mailer.asset_host.presence
      return configured if configured

      options = ActionMailer::Base.default_url_options || {}
      host = options[:host].presence
      return nil if host.nil?
      return host if host.start_with?("http")

      "#{mailer_protocol(options, host)}://#{host}#{mailer_port_suffix(options)}"
    rescue StandardError
      nil
    end

    # Honor an explicit :protocol. Otherwise https — EXCEPT on loopback, which is
    # a dev stack with no TLS. Defaulting the other way would downgrade every
    # production app that sets only {host: "mcritchie.studio"}.
    def mailer_protocol(options, host)
      explicit = options[:protocol].presence
      return explicit.to_s.sub(%r{://\z}, "") if explicit

      LOOPBACK_HOSTS.include?(host.downcase) ? "http" : "https"
    end

    # Ports are part of the origin, and omitting one sends the reader to :443.
    # The scheme defaults are left off so a normal URL stays normal.
    def mailer_port_suffix(options)
      port = options[:port]
      return "" if port.blank? || [80, 443].include?(port.to_i)

      ":#{port}"
    end

    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 0.0.0.0 ::1].freeze

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
