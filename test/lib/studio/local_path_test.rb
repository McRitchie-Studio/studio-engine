# frozen_string_literal: true

require "test_helper"
require "studio/local_path"
require "studio/link_token"
require "studio/booking"

# [unit] Studio::LocalPath.local? — the one rule every engine path sanitizer
# applies before a caller-supplied path reaches a redirect or an href.
class StudioLocalPathTest < Minitest::Test
  LOCAL = ["/", "/ok", "/contests/world-cup", "/a/b?c=d#e"].freeze

  # Each row is a way a browser leaves the site from a "path".
  REJECTED = {
    "//x"         => "protocol-relative: another host",
    "/\\x"        => "a browser reads a backslash as a slash: //x",
    "/\\/x"       => "backslash then slash: //x again",
    "\t/x"        => "a tab before the leading slash",
    "/\tx"        => "a tab inside, which the URL parser strips",
    "/\n/x"       => "a newline the URL parser strips, hiding //x",
    "/\x7Fx"      => "DEL",
    "https://x"   => "an absolute URL",
    "javascript:x" => "a scheme",
    "x"           => "a relative path",
    ""            => "blank",
    " "           => "whitespace"
  }.freeze

  def test_a_local_path_passes
    LOCAL.each { |path| assert Studio::LocalPath.local?(path), path.inspect }
  end

  def test_every_off_site_shape_is_rejected
    REJECTED.each { |path, why| refute Studio::LocalPath.local?(path), "#{path.inspect} (#{why})" }
  end

  def test_nil_is_not_local
    refute Studio::LocalPath.local?(nil)
  end

  # The sites that used to carry their own copy of the rule now agree with it,
  # row for row. A site that drifts back to a bare start_with? check fails here.
  def test_link_token_sanitizer_follows_the_rule
    LOCAL.each { |path| assert_equal path, Studio::LinkToken.sanitize_path(path) }
    REJECTED.each_key { |path| assert_nil Studio::LinkToken.sanitize_path(path), path.inspect }
  end

  def test_booking_local_path_follows_the_rule
    LOCAL.each { |path| assert Studio::Booking.local_path?(path), path.inspect }
    REJECTED.each_key { |path| refute Studio::Booking.local_path?(path), path.inspect }
  end
end
