# frozen_string_literal: true

module Studio
  # /marketing-kit: the app's logos, colours and typefaces, for anyone to use.
  # See Studio::MarketingKit and docs/SITE_FOOTER.md.
  #
  # Public by design: a journalist or a partner has no account. It inherits the
  # host's ApplicationController so the page renders in the app's layout, navbar
  # and theme, and it skips each gate a host is known to put there:
  # Studio::ErrorHandling's sign-in gate (every adopter), the hub's admin wall,
  # and turf-monster's profile-completion redirect. A host with a gate of another
  # name skips it in a to_prepare block (docs/SITE_FOOTER.md).
  #
  # It reads no table and no session, so an app with neither can draw it.
  class MarketingKitController < ::ApplicationController
    HOST_GATES = %i[require_authentication require_admin_wall require_admin require_login
                    authenticate_user! require_profile_completion].freeze

    HOST_GATES.each { |gate| skip_before_action gate, raise: false }

    def show; end
  end
end
