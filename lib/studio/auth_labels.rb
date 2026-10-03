# frozen_string_literal: true

# The words the engine's own auth pages say for "sign in", derived from the one
# setting the navbar already reads, Studio.sign_in_label (default "Log in";
# lib/studio/navbar_identity.rb). An app that says "Sign in" in its navbar gets
# "Sign in" on /login, /signup and the magic-link pages too, never a mix.
#
# Every form is derived from the label as written:
#
#   label "Sign in"   link "Sign in"   button "Sign In"
#                     prompt "Sign in to continue"
#                     to_app "Sign in to Cyvasse"
#                     or_below "or sign in below"
#                     link_noun "sign-in link"
#
# THE DEFAULT IS PINNED, NOT DERIVED. With the default label the pages print
# exactly what they printed before this setting reached them, and that text was
# itself mixed: "Log in to continue" and "Log In" beside "Sign in to <App>",
# "or sign in below" and "sign-in link". So the three forms that said "sign in"
# under the default keep saying it while the label is the default, and follow the
# label only once an app configures another one. An app that never configures
# the label renders byte-identical pages (test/integration/auth_page_labels_render_test.rb).
#
# Pure Ruby, so the unit suite covers it without the dummy app.
require_relative "navbar_identity"

module Studio
  module AuthLabels
    DEFAULT = NavbarIdentity::DEFAULT_SIGN_IN_LABEL

    module_function

    def configured?(label)
      label.to_s != DEFAULT
    end

    # The sign-up page's "Already have an account?" link.
    def link(label)
      label.to_s
    end

    # The login form's submit button, in title case: "Log In", "Sign In".
    def button(label)
      label.to_s.split(" ").map { |word| capitalize_first(word) }.join(" ")
    end

    # The login page's line under the app name.
    def prompt(label)
      "#{label} to continue"
    end

    # The magic-link confirm page's fallback button.
    def to_app(label, app_name)
      "#{configured?(label) ? label : 'Sign in'} to #{app_name}"
    end

    # The divider under the SSO "Continue as" button.
    def or_below(label)
      configured?(label) ? "or #{label.to_s.downcase} below" : "or sign in below"
    end

    # The emailed link's noun: the magic-link button and the "sent" notice.
    def link_noun(label)
      configured?(label) ? "#{label.to_s.downcase.tr(' ', '-')} link" : "sign-in link"
    end

    # Only the first letter changes, so an already-capital word is untouched.
    def capitalize_first(word)
      word.sub(/\A\p{Ll}/) { |c| c.upcase }
    end
  end
end
