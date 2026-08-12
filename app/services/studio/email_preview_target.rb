module Studio
  # WHO the email manager previews an email as.
  #
  # The banner's header is per-recipient ("Welcome Mason!"), so "what does this
  # email look like" has no answer until you say who is receiving it. The page
  # offers a small set of real people to stand in, and every variable on the page
  # — first name, email — comes from the chosen one.
  #
  # ## Why real records rather than made-up samples
  #
  # A fabricated "Sample User <sample@example.com>" previews a person who cannot
  # receive mail, and it hides the failures that actually happen: an account with
  # no display name, a name that is one word, a name long enough to wrap the
  # banner. Reading the host's own users puts those in front of the operator.
  #
  # ## Why an ADMIN and a MEMBER
  #
  # They differ in the ways that break email. An admin is usually the operator
  # themselves — a full name on file, an internal address. A member is whoever
  # signed up: often no name at all, which is the case that renders "Welcome !"
  # if the fallback header is wrong. Being able to flip between them is how that
  # gets caught here rather than in someone's inbox.
  #
  # Nil-safe throughout. The host's User model may be absent, may not respond to
  # `admin?`, may have no rows. The preview degrades to a synthetic stand-in
  # rather than taking the manager down — this is a page for looking at pictures.
  class EmailPreviewTarget
    ATTRIBUTES = %i[id label name email admin avatar_url avatar_color].freeze
    attr_reader(*ATTRIBUTES)

    def initialize(id:, label:, name: nil, email: nil, admin: false,
                   avatar_url: nil, avatar_color: nil, initials: nil)
      @id = id.to_s
      @label = label
      @name = name.presence
      @email = email.presence
      @admin = admin
      @avatar_url = avatar_url.presence
      @avatar_color = avatar_color.presence || DEFAULT_AVATAR_COLOR
      @initials = initials.presence
    end

    # The HOST's own initials when it has them, so this circle matches the one in
    # the navbar rather than being a second opinion about the same person.
    # Falls back to the address when there is no name, because "no name on file"
    # is the ordinary case for a member and an empty circle identifies nobody.
    def initials
      return @initials if @initials

      source = name.presence || email.to_s.split("@").first.to_s
      parts = source.split(/[\s._-]+/).reject(&:empty?)
      return "?" if parts.empty?

      (parts.length == 1 ? parts.first[0, 2] : parts.first(2).map { |part| part[0] }.join).upcase
    end

    DEFAULT_AVATAR_COLOR = "#6b7280".freeze

    def admin? = !!@admin
    def first_name = name.to_s.strip.split.first
    def to_param = id

    # A stand-in used only when the host has no matching user. Named as a sample
    # so nobody mistakes the preview for a real account.
    def sample? = id.start_with?("sample-")

    class << self
      # Every target the page can offer, admin first.
      def all
        [find_admin, find_member].compact
      end

      # The one to preview as. Falls back to the first available rather than
      # erroring on a stale id from a bookmarked URL.
      def resolve(id)
        list = all
        list.find { |target| target.id == id.to_s } || list.first
      end

      private

      def find_admin
        record = first_user { |scope| admins(scope) }
        return sample_admin if record.nil?

        from_record(record, id_prefix: "admin", label: "Admin", admin: true)
      end

      def find_member
        record = first_user { |scope| members(scope) }
        return sample_member if record.nil?

        from_record(record, id_prefix: "member", label: "Member", admin: false)
      end

      # The host's User model, or nil. `safe_constantize` rather than defined?()
      # so an app without one simply has no records to offer.
      def user_model
        model = "User".safe_constantize
        return nil unless model.respond_to?(:all) && model.respond_to?(:column_names)

        model
      end

      def first_user
        model = user_model
        return nil if model.nil?

        yield(model)
      rescue StandardError
        # A missing table, a mid-migration column, a host User that is not an
        # ActiveRecord at all. None of them should cost more than the dropdown.
        nil
      end

      # `admin` may be a column, a method, or absent entirely. Only the column
      # can be queried; anything else is filtered in Ruby over a bounded slice,
      # because a preview must not table-scan a production users table.
      def admins(model)
        return model.where(admin: true).first if model.column_names.include?("admin")

        model.limit(50).detect { |user| user.try(:admin?) }
      end

      def members(model)
        return model.where(admin: [false, nil]).first if model.column_names.include?("admin")

        model.limit(50).detect { |user| !user.try(:admin?) }
      end

      def from_record(record, id_prefix:, label:, admin:)
        new(id: "#{id_prefix}-#{record.id}", label: label, admin: admin,
            name: display_name_for(record), email: record.try(:email),
            avatar_url: avatar_url_for(record), avatar_color: record.try(:avatar_color),
            initials: record.try(:avatar_initials))
      end

      # ActiveStorage, defensively. A host may not attach avatars at all, the blob
      # may be missing, and url helpers need a host that a background job does not
      # have — none of which should cost more than a plain initials circle.
      def avatar_url_for(record)
        avatar = record.try(:avatar)
        return nil unless avatar.respond_to?(:attached?) && avatar.attached?

        Rails.application.routes.url_helpers.rails_blob_path(avatar, only_path: true)
      rescue StandardError
        nil
      end

      # "Is there a REAL name on file", not "what should we call this person".
      #
      # display_name is asked LAST and only when the record has no name attribute
      # at all. It is a presentation helper: McRitchie Studio's synthesises one
      # from the email address, so member@… came back as "Member" and the
      # nameless member — the entire reason that option exists — previewed as
      # somebody with a name. A blank `name` is the honest nil.
      def display_name_for(record)
        return record.name.presence if record.respond_to?(:name)
        return record.full_name.presence if record.respond_to?(:full_name)

        record.try(:display_name).presence
      end

      # The app's own domain, read off the configured from-address rather than
      # a new config knob — a sample address on some other domain would look
      # like a real account somewhere else.
      def sample_domain
        Studio.mailer_from.to_s[/@([^\s>]+)/, 1].presence || "example.com"
      rescue StandardError
        "example.com"
      end

      def sample_admin
        new(id: "sample-admin", label: "Admin (sample)", admin: true,
            name: "Alex McRitchie", email: "alex@#{sample_domain}")
      end

      # Deliberately NAMELESS. The member stand-in exists to show the operator
      # what someone with no name on file receives, which is the case the header
      # fallback is for and the one nobody thinks to check.
      def sample_member
        new(id: "sample-member", label: "Member (sample)", admin: false,
            name: nil, email: "member@#{sample_domain}")
      end
    end
  end
end
