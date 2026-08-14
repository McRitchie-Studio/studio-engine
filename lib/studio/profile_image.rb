# frozen_string_literal: true

# The house rule for "is this upload an acceptable profile picture?" — one
# allowlist, one size cap, in one place.
#
# Pure Ruby and duck-typed on purpose: it takes anything answering
# `content_type` and `size`, which is what an ActionDispatch::Http::UploadedFile
# answers, so the rule is unit-testable without Rails, a request, or a users
# table.
#
# LIFTED FROM turf-monster, where this lived as ApplicationController#valid_image?
# with an IMAGE_UPLOAD_TYPES constant beside it. Same allowlist, same 8 MB cap —
# the values are turf's, deliberately, because they are the ones that have been
# in front of real uploads. What changes is that the second and third app no
# longer have to re-derive them.
#
# ON THE ALLOWLIST BEING AN ALLOWLIST: an avatar is attacker-supplied bytes that
# the app then serves back to other people. Naming the three formats we accept is
# what keeps an SVG — which is a script host, not a picture — from becoming a
# profile photo. Do not widen this to a `start_with?("image/")` check.
module Studio
  module ProfileImage
    ALLOWED_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze

    # 8 MB. Phone cameras clear this comfortably; it is a bound on abuse, not on
    # the user's actual photo.
    MAX_BYTES = 8 * 1024 * 1024

    # A human sentence for the rejection path. Kept next to the rule so the two
    # cannot drift — a message naming the wrong limit is worse than none.
    MESSAGE = "Use a PNG, JPG, or WebP under 8 MB."

    module_function

    def acceptable?(file)
      return false unless file.respond_to?(:content_type) && file.respond_to?(:size)
      return false unless ALLOWED_CONTENT_TYPES.include?(file.content_type)

      size = file.size
      size.is_a?(Numeric) && size.positive? && size <= MAX_BYTES
    end
  end
end
