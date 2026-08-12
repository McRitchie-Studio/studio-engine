module Studio
  # A LAYERED email banner: a background image with the header, sub-text and
  # logo sitting on top as live HTML, rather than composed into the picture.
  #
  # ## Why layered rather than composited
  #
  # The alternative is drawing the text into the image server-side. That gives
  # pixel-exact brand typography in every client, but it cannot do the one thing
  # this design needs: an ANIMATED background WITH per-recipient text. Composing
  # "Welcome Mason!" into sixty frames means a multi-megabyte GIF generated per
  # recipient, per send.
  #
  # Layering separates them. The background animates, the greeting is live, and
  # nothing is generated at send time.
  #
  # ## What it costs, stated plainly
  #
  # Gmail and Outlook strip webfonts, so the heading falls back to a system face
  # rather than the brand font. In exchange the text survives blocked images
  # (which Outlook desktop does by default), stays selectable and translatable,
  # and no asset is produced per send.
  #
  # ## Why the markup looks like 1999
  #
  # Outlook on Windows renders through Word, which ignores `background-image` on
  # nearly everything. The `<td background>` attribute plus a VML `v:rect` /
  # `v:fill` block — the long-established "bulletproof background" pattern — is
  # what makes a background image work there at all. The conditional comment is
  # invisible to every other client.
  # A plain class, not a Struct-with-block: constants declared inside a
  # `Struct.new do ... end` attach to the ENCLOSING module, so DEFAULT_SCRIM
  # would have been Studio::DEFAULT_SCRIM and Banner::DEFAULT_SCRIM would not
  # exist. Named constants are part of this object's API, so they live on it.
  class Banner
    ATTRIBUTES = %i[background_url header subtext logo_url logo_alt scrim width height].freeze
    attr_reader(*ATTRIBUTES)

    def initialize(**attrs)
      unknown = attrs.keys - ATTRIBUTES
      raise ArgumentError, "unknown banner attribute: #{unknown.join(", ")}" if unknown.any?

      ATTRIBUTES.each { |name| instance_variable_set(:"@#{name}", attrs[name]) }
    end

    # The email card is 600px wide; the banner fills it.
    DEFAULT_WIDTH  = 600
    DEFAULT_HEIGHT = 200

    # A wash between the artwork and the text. Not decoration: background art is
    # chosen for looks, not contrast, and white text over a pale sky is
    # unreadable. 0 disables it for artwork already dark enough to carry type.
    #
    # Raised from 0.34 after seeing it in a real inbox — bright artwork left the
    # sub-text working harder than it should. Rendered at 0.34 / 0.45 / 0.55 and
    # chosen by eye, because "legible" is a judgement about a picture, not a
    # number a test can settle.
    DEFAULT_SCRIM = 0.40

    def width  = (@width  || DEFAULT_WIDTH).to_i
    def height = (@height || DEFAULT_HEIGHT).to_i

    def scrim_opacity
      value = @scrim
      return DEFAULT_SCRIM if value.nil?

      value.to_f.clamp(0.0, 1.0)
    end

    # A banner with nothing to show is not a banner. The layout falls back to
    # the plain <img> path (or to no banner at all).
    def renderable? = background_url.present? || header.present?

    # Everything the layout needs for one email, or nil.
    #
    # Reads the catalogue for the artwork so an app inherits the shared
    # background and logo without repeating them, and lets a caller override any
    # piece per send — which is the whole point of the header being dynamic.
    # `name` is the DYNAMIC part and the only thing a mailer should normally
    # pass. A mailer that hands over a finished header instead takes the wording
    # away from the operator: the /admin/emails field would still accept an edit
    # and the email would still ignore it — a control that lies about what it
    # does. So the mailer supplies who the person is, and the operator supplies
    # what the banner says about them.
    def self.for(key, name: nil, header: nil, subtext: nil, background_url: nil,
                 logo_url: nil, scrim: nil, logo_alt: nil)
      banner = new(
        background_url: background_url || Studio::EmailCatalog.background_url(key),
        logo_url:       logo_url       || Studio::EmailCatalog.resolved_logo_url(key),
        logo_alt:       logo_alt       || Studio.app_name,
        header:         header         || header_for(key, name),
        subtext:        subtext        || Studio::EmailCatalog.subtext(key),
        # Resolution order: an explicit argument (a caller who knows better),
        # then what the OPERATOR saved on /admin/emails, then the registry, then
        # the default. The operator sits above the registry on purpose — they
        # are the one looking at the artwork.
        scrim:          scrim || Studio::EmailCatalog.scrim(key)
      )
      banner.renderable? ? banner : nil
    end

    # The placeholder an operator types into the header field. Braces rather
    # than Ruby's %{name}: an operator-editable string is passed to no formatter
    # here, and a stray "%" in "50% off" would raise inside format() where a
    # stray brace is simply left alone.
    NAME_PLACEHOLDER = "{name}".freeze

    # The app's own name. Present because the DEFAULTS need it: "Your sign-in
    # link" reads as though it could be from anyone, and a registry constant
    # cannot interpolate Studio.app_name at load time. An operator gets it for
    # free in any field.
    APP_PLACEHOLDER = "{app}".freeze

    # FIRST name only. The banner is one line of large type in a 600px box, and
    # "Welcome Bartholomew Fitzgerald-Montgomery!" wraps out of it.
    # Shared with the SUBJECT, which takes the same placeholder. One
    # implementation, so "{name}" cannot mean two things on one email.
    def self.interpolate(template, name)
      text = template.to_s.gsub(APP_PLACEHOLDER, Studio.app_name.to_s)
      first = name.to_s.strip.split.first
      return text.gsub(NAME_PLACEHOLDER, first) if first.present?

      # NO NAME, AND NO RAW PLACEHOLDER EITHER. The header carries a whole second
      # field for this case; a subject line does not, and "Sign in to Studio,
      # {name}" reaching an inbox is the most visible way this feature fails. The
      # token goes, and the punctuation it hung off goes with it — the result is
      # "Sign in to Studio", not "Sign in to Studio, ".
      # Two passes, because the punctuation can sit on either side: "Sign in,
      # {name}" and "{name}, your link is here" both have to come out clean, and
      # "Hi {name} welcome" must not become "Hiwelcome".
      text.gsub(/[,;:\u2014-]?\s*#{Regexp.escape(NAME_PLACEHOLDER)}/, "")
          .sub(/\A\s*[,;:\u2014-]\s*/, "")
          .squeeze(" ").strip
    end

    def self.header_for(key, name)
      template = Studio::EmailCatalog.header_template(key).to_s
      first = name.to_s.strip.split.first

      return interpolate(template, name) if first.present?
      # No name: a template that asks for one cannot be rendered honestly, so
      # the fallback answers instead. A template with no name placeholder is
      # already name-free and stands as written — still interpolated, because
      # {app} does not depend on the recipient.
      fallback = Studio::EmailCatalog.header_fallback(key) if template.include?(NAME_PLACEHOLDER)

      interpolate(fallback || template, nil)
    end
  end

end
