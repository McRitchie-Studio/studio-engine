# frozen_string_literal: true

module Studio
  # The one rule for "is this a path on THIS site?", used wherever the engine
  # writes a caller-supplied path into a redirect or an href: a sign-in's
  # return_to, a link's target, the booking page, the link-preview fallback image.
  #
  # A local path begins with exactly one "/" and carries no control character
  # and no backslash. Each clause closes a way a browser leaves the site:
  #   "https://x", "javascript:x"  - no leading "/": a scheme or a relative path
  #   "//x"                        - protocol-relative: another host
  #   "/\x", "/\/x"                - browsers (the WHATWG URL parser) read "\" as
  #                                  "/", so these are "//x" in disguise
  #   "/\tx", "/\nx"               - the URL parser strips tab and newline, so a
  #                                  control character can hide a second "/"
  # Pure Ruby, so it loads and unit-tests without Rails.
  module LocalPath
    # A control character (C0 or DEL) or a backslash anywhere in the path.
    UNSAFE_CHARACTER = /[\x00-\x1f\x7f\\]/

    module_function

    def local?(path)
      string = path.to_s
      string.start_with?("/") && !string.start_with?("//") && !string.match?(UNSAFE_CHARACTER)
    end
  end
end
