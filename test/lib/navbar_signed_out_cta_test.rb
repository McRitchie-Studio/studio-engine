# frozen_string_literal: true

require "test_helper"

# [unit] Config rules for Studio.navbar_signed_out_cta
# (lib/studio/navbar_signed_out_cta.rb): nil stays the sign-in button, a Hash of
# label and path normalizes to plain Strings, a callable resolves per view, and
# a bad shape raises rather than rendering a broken navbar.
class NavbarSignedOutCtaTest < Minitest::Test
  C = Studio::NavbarSignedOutCta

  # The unit helper mirrors Studio's attributes without the writers, so these
  # tests drive the module; the dummy-app render test pins the Studio writer.

  def test_nil_resolves_to_nil_and_validates
    assert_nil C.resolve(nil, Object.new)
    assert_nil C.validate!(nil)
  end

  def test_a_hash_resolves_to_label_and_path
    assert_equal({ label: "Build App", path: "/build" }, C.resolve({ label: "Build App", path: "/build" }, Object.new))
  end

  def test_string_keys_and_padding_normalize_the_same
    assert_equal({ label: "Build App", path: "/build" }, C.normalize({ "label" => " Build App ", "path" => "/build" }))
  end

  def test_html_safe_values_come_back_plain_so_erb_escapes_them
    resolved = C.normalize({ label: "<b>x</b>".html_safe, path: "/build" })

    refute_predicate resolved[:label], :html_safe?
  end

  def test_a_callable_receives_the_view
    view = Struct.new(:build_path).new("/build?from=nav")
    cta = ->(v) { { label: "Build App", path: v.build_path } }

    assert_nil C.validate!(cta), "a callable is checked when it resolves, not at assignment"
    assert_equal({ label: "Build App", path: "/build?from=nav" }, C.resolve(cta, view))
  end

  def test_a_callable_answering_nil_keeps_the_sign_in_button
    assert_nil C.resolve(->(_view) {}, Object.new)
  end

  def test_a_raising_callable_falls_back_to_the_sign_in_button
    C.reset_reported!

    assert_nil C.resolve(->(_view) { raise "no route" }, Object.new)
  end

  def test_a_bad_callable_answer_is_refused_when_it_resolves
    error = assert_raises(C::InvalidConfig) { C.resolve(->(_view) { "/build" }, Object.new) }
    assert_match(/Hash/, error.message)
  end

  def test_bad_static_settings_are_refused
    assert_raises(C::InvalidConfig) { C.validate!("/build") }
    assert_raises(C::InvalidConfig) { C.validate!({ label: "Build App" }) }
    assert_raises(C::InvalidConfig) { C.validate!({ label: " ", path: "/build" }) }
    assert_raises(C::InvalidConfig) { C.validate!({ label: "Build App", path: 7 }) }
  end

  def test_an_unknown_key_is_refused_rather_than_ignored
    error = assert_raises(C::InvalidConfig) { C.validate!({ label: "Build App", path: "/build", href: "/build" }) }
    assert_match(/:href/, error.message)
  end
end
