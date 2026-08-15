# frozen_string_literal: true

# Resolves Studio.profile_sections — the rows that make up the shared /profile
# page — for a given view context. Pure Ruby (no Rails dependency) so the unit
# suite exercises the resolution rules without booting the dummy app.
#
# THE SHAPE IS DELIBERATELY THE SIDEBAR'S. Studio.sidebar_sections already taught
# this codebase one way to let a host declare page furniture: a static Array or a
# callable that receives the view, symbolized on the way out, with sections the
# viewer may not see dropped before render. Reusing that shape means a host that
# has declared a sidebar already knows how to declare a profile.
#
# What a section looks like:
#
#   { key: :name, title: "Name", page: :edit, partial: "studio/profiles/name_fields",
#     locals: { ... }, requires: :first_name, admin: false }
#
#   key      — stable identifier. A host removes or replaces a default by key,
#              so reordering the defaults never breaks a host's override.
#   title    — the row's heading.
#   partial  — the partial to render. Host partials are ordinary app views.
#   locals   — optional Hash passed to the partial.
#   requires — optional attribute (or Array of them) the CURRENT USER must
#              respond to for the row to render. See below.
#   admin    — admin-only row, same rule as the sidebar's.
#   if       — optional callable. The row renders only when it returns truthy.
#              Called with the view when it takes an argument, without when it
#              does not. This is the APP-CAPABILITY gate, distinct from
#              `requires:` which is the MODEL gate — and the two really are
#              different questions. Every consumer's users table carries
#              `provider` and `uid`, so `requires:` alone selected the whole
#              fleet for the Google row; mcritchie-industries has those columns
#              AND `auth_methods = %i[magic_link]` with no omniauth gem at all,
#              so it would have rendered a "Link Google Account" button leading
#              nowhere. Having a column is not the same as offering the feature.
#   modals   — the row opens the shared crop/saving modals. The PAGE mounts them
#              once (studio/modals/_scoped_host on a "profileModals" store) when
#              any resolved row asks for them, so a row never has to know whether
#              the host app renders a modal host of its own. Two of the five
#              consumers render none at all, and the two that do ship a FORK of
#              the engine's shared host that would shadow it.
#
# ON `requires` — this is the whole reason the registry exists rather than a
# hardcoded page. The consuming apps do NOT agree on their users table:
# mcritchie-industries has eight columns and no `first_name`; turf-monster has
# forty. A shared page that assumed a column would raise NoMethodError on every
# signed-in request in the app that lacked it — the same failure mode
# Studio.first_name_outstanding? already guards against with respond_to?.
#
# So a row DECLARES what it needs and is dropped when the host cannot serve it.
# mcritchie-industries gets a working edit page with an email field and no name
# or birthday fields until it installs the standard-profile-columns migration, at
# which point they appear with no code change. Silence, not a 500.
module Studio
  module ProfileSections
    # Which page a row belongs to. `:show` is the read page (/profile) — things
    # you look at and occasionally act on; `:edit` is the form (/profile/edit).
    PAGES = %i[show edit].freeze

    # The rows every consumer gets for free.
    #
    # THE AVATAR IS NOT HERE, and that is a change rather than an omission: it
    # moved into the identity header both pages render, where it sits with the
    # display name and the address. It stopped being a row when it stopped
    # looking like one.
    DEFAULTS = [
      # --- the read page ------------------------------------------------------
      # Google is an identity you CONNECT, not a field you type, which is why it
      # reads rather than edits. Gated on the app OFFERING Google, not merely on
      # having the columns — the same question app/views/sessions/new.html.erb
      # already asks before drawing this identical button on the login page.
      { key: :google, title: "Google account", page: :show,
        partial: "studio/profiles/google_section", requires: %i[provider uid],
        if: -> { Studio.auth_method?(:google) } },

      # --- the edit page ------------------------------------------------------
      # These are FIELDS in one form with one Save, so they carry no buttons of
      # their own. Email included: it needed a separate action only while it was
      # out-of-band, and now that it applies directly there is no reason for a
      # second mechanism on the same page. Its side effects — the Google lock,
      # notifying the old address, invalidating other sessions — are the server's
      # business, not the form's.
      { key: :name, title: "Name", page: :edit,
        partial: "studio/profiles/name_fields", requires: :first_name },
      { key: :email, title: "Email", page: :edit,
        partial: "studio/profiles/email_fields", requires: :email },
      { key: :birthday, title: "Birthday", page: :edit,
        partial: "studio/profiles/birthday_fields", requires: %i[birth_day birth_month birth_year] }
    ].freeze

    module_function

    # A fresh, mutable copy every call. Hosts compose with `+` and sometimes
    # `reject`, and handing out the frozen literal would let one host's edit
    # leak into the next request's page.
    def defaults
      DEFAULTS.map { |section| section.dup }
    end

    # Declared may be nil (the host has said nothing — it gets the defaults), an
    # Array, or a callable receiving the view context.
    #
    # `nil` meaning "the defaults" rather than "no sections" is the load-bearing
    # choice here: it is what makes a brand-new app's profile page work with an
    # empty initializer, which is the entire point of standardizing this.
    # `page:` selects a subset. nil means every page, which is what the pre-split
    # callers passed and what a host asking "all of them" wants.
    def resolve(declared, view, page: nil)
      sections = declared.respond_to?(:call) ? declared.call(view) : declared
      sections = defaults if sections.nil?

      admin = view.respond_to?(:admin?) && view.admin?
      user  = view.respond_to?(:current_user) ? view.current_user : nil

      Array(sections)
        .map { |section| symbolize(section) }
        .reject { |section| page && page_of(section) != page.to_sym }
        .reject { |section| section[:admin] && !admin }
        .select { |section| enabled?(section[:if], view) }
        .select { |section| served_by?(user, section[:requires]) }
    end

    # The app-capability gate. No `if:` means always enabled. The callable takes
    # the view when it wants one and nothing when it does not, so a host can
    # write either `-> { Studio.feature?(:x) }` or `->(view) { view.admin? }`.
    def enabled?(condition, view)
      return true if condition.nil?

      # A Symbol/String names a method on the VIEW — Rails' own
      # `before_action ..., if: :method_name` convention, and therefore the most
      # natural thing a host will write here.
      #
      # It is handled explicitly because the alternative FAILS OPEN: a Symbol
      # does not answer `call`, so the earlier `return !!condition` coerced
      # `:some_predicate` to true and rendered the row unconditionally — a gate
      # that silently does nothing, in the same permissive direction as the bug
      # this whole `if:` key was added to fix. A host would have had no signal.
      if condition.is_a?(Symbol) || condition.is_a?(String)
        unless view.respond_to?(condition)
          # SILENT would repeat the bug this key was added to fix. The old
          # coercion gave the host no signal; dropping the row without one only
          # moves the silence somewhere safer. A typo'd gate now says so.
          warn_gate("profile_sections: `if: #{condition.inspect}` names a method the view " \
                    "does not answer — the row was dropped. Check the spelling.")
          return false
        end

        # Arity-aware, matching the lambda branch below: a predicate written as
        # `def visible?(view)` is as natural as one written without an argument,
        # and calling it wrong raises ArgumentError — which surfaces as a 500 on
        # /profile rather than as a dropped row.
        method = view.method(condition)
        return !!(method.arity.zero? ? view.public_send(condition) : view.public_send(condition, view))
      end

      return !!condition unless condition.respond_to?(:call)

      !!(condition.arity.zero? ? condition.call : condition.call(view))
    end

    # Can this host's user model serve the row? No requirement means yes — a row
    # that reads nothing off the user (a static explainer, a link out) is always
    # served. A nil user means we are rendering for nobody, and nothing is served.
    # A row that never says defaults to :edit — someone adding a row is usually
    # adding a field, and the read page is a deliberate, curated surface.
    def page_of(section)
      (section[:page] || :edit).to_sym
    end

    def served_by?(user, requires)
      needed = Array(requires).compact
      return true if needed.empty?
      return false if user.nil?

      needed.all? { |attribute| user.respond_to?(attribute) }
    end

    # Pure Ruby: this file loads without Rails, so it cannot assume a logger.
    def warn_gate(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        Kernel.warn(message)
      end
    end

    def symbolize(hash)
      out = hash.to_h.each_with_object({}) { |(key, value), acc| acc[key.to_sym] = value }

      # `key` is an IDENTIFIER, so its VALUE symbolizes too — unlike every other
      # field, whose value is data. A host composing by key writes
      # `reject { |s| s[:key] == :avatar }`, and that silently matches nothing if
      # a section declared with string keys kept `"avatar"` as a String. Removing
      # a standard row is the documented seam; it must not depend on which
      # spelling the host happened to use.
      out[:key] = out[:key].to_sym if out[:key].respond_to?(:to_sym)
      out
    end
  end
end
