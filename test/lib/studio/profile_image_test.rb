# frozen_string_literal: true

require "test_helper"

# [unit] The house rule for an acceptable profile picture
# (lib/studio/profile_image.rb), lifted from turf-monster's
# ApplicationController#valid_image? so the second and third app stop
# re-deriving it.
#
# The security-relevant property is the ALLOWLIST. An avatar is attacker-supplied
# bytes the app serves back to other people, so the rejection cases here are the
# point of the file — particularly SVG, which is a script host wearing an image's
# content type.
class ProfileImageTest < Minitest::Test
  Upload = Struct.new(:content_type, :size)

  def test_accepts_the_three_allowed_types
    %w[image/png image/jpeg image/webp].each do |type|
      assert Studio::ProfileImage.acceptable?(Upload.new(type, 1_024)), "#{type} should be accepted"
    end
  end

  # THE REASON THE ALLOWLIST IS AN ALLOWLIST. An SVG is markup that browsers
  # execute; served back as someone's avatar it is stored XSS. A
  # `start_with?("image/")` check — the obvious "simplification" — accepts it.
  def test_rejects_svg
    refute Studio::ProfileImage.acceptable?(Upload.new("image/svg+xml", 1_024))
  end

  def test_rejects_non_image_types
    refute Studio::ProfileImage.acceptable?(Upload.new("application/pdf", 1_024))
    refute Studio::ProfileImage.acceptable?(Upload.new("text/html", 1_024))
    refute Studio::ProfileImage.acceptable?(Upload.new("", 1_024))
    refute Studio::ProfileImage.acceptable?(Upload.new(nil, 1_024))
  end

  def test_accepts_a_file_exactly_at_the_cap
    assert Studio::ProfileImage.acceptable?(Upload.new("image/png", Studio::ProfileImage::MAX_BYTES))
  end

  def test_rejects_a_file_one_byte_over_the_cap
    refute Studio::ProfileImage.acceptable?(Upload.new("image/png", Studio::ProfileImage::MAX_BYTES + 1))
  end

  def test_rejects_an_empty_file
    refute Studio::ProfileImage.acceptable?(Upload.new("image/png", 0)),
      "a zero-byte upload is a failed pick, not a picture"
  end

  # Duck-typed on purpose (it takes whatever the request handed the controller),
  # so the shape check has to be real rather than assumed.
  #
  # NOTE for anyone extending this: do NOT reach for `Struct.new(:content_type)`
  # as the "missing size" double. A Struct answers `size` — its MEMBER COUNT, 1 —
  # so it satisfies the duck type and is accepted as a 1-byte PNG. That is a
  # property of Struct, not a hole in the rule, but it makes Struct the wrong
  # tool for this particular case.
  def test_rejects_objects_that_are_not_uploads
    refute Studio::ProfileImage.acceptable?(nil)
    refute Studio::ProfileImage.acceptable?("just-a-string")
    refute Studio::ProfileImage.acceptable?(Object.new)
  end

  def test_rejects_an_object_carrying_a_type_but_no_size
    type_only = Class.new { def content_type = "image/png" }.new

    refute Studio::ProfileImage.acceptable?(type_only)
  end

  def test_rejects_a_non_numeric_size
    refute Studio::ProfileImage.acceptable?(Upload.new("image/png", "1024"))
  end

  # The message names the limit. Kept beside the rule so the two cannot drift —
  # a rejection sentence citing the wrong number is worse than none.
  def test_the_message_agrees_with_the_rule
    assert_equal 8 * 1024 * 1024, Studio::ProfileImage::MAX_BYTES
    assert_includes Studio::ProfileImage::MESSAGE, "8 MB"
    Studio::ProfileImage::ALLOWED_CONTENT_TYPES.each do |type|
      label = type.split("/").last.sub("jpeg", "JPG").upcase
      assert_includes Studio::ProfileImage::MESSAGE.upcase, label,
        "#{type} is accepted but the message does not mention it"
    end
  end
end
