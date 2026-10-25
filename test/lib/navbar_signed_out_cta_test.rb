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
  # ---- the optional keys: modal, sign_in_link, sign_in_path ----

  BASE = { label: "Sign in", path: "/signin" }.freeze

  def test_absent_optional_keys_add_nothing_to_the_cta
    assert_equal BASE, C.normalize(BASE)
    assert_equal BASE, C.normalize(BASE.merge(modal: nil, sign_in_path: nil))
  end

  def test_a_modal_id_normalizes_to_an_id_with_no_props
    assert_equal({ id: "auth", props: {} }, C.normalize(BASE.merge(modal: :auth))[:modal])
  end

  def test_modal_props_normalize_to_json_with_string_keys
    cta = C.normalize(BASE.merge(modal: { "id" => "auth", "props" => { step: :credentials, submitting: nil,
                                                                       tries: [1, 2.5, true] } }))

    assert_equal({ id: "auth", props: { "step" => "credentials", "submitting" => nil, "tries" => [1, 2.5, true] } },
                 cta[:modal])
  end

  def test_a_modal_id_must_be_a_plain_name
    ["auth'); alert(1); ('", "", "a b", 42, nil].each do |id|
      error = assert_raises(C::InvalidConfig, id.inspect) { C.normalize(BASE.merge(modal: { id: id })) }
      assert_match(/:modal needs an :id that is a plain name/, error.message)
    end
  end

  def test_modal_props_must_be_json
    error = assert_raises(C::InvalidConfig) { C.normalize(BASE.merge(modal: { id: "auth", props: { at: Object.new } })) }
    assert_match(/:modal :props\[:at\] must be JSON/, error.message)
    assert_raises(C::InvalidConfig) { C.normalize(BASE.merge(modal: { id: "auth", props: "step=1" })) }
    assert_raises(C::InvalidConfig) { C.normalize(BASE.merge(modal: { id: "auth", props: { 1 => "x" } })) }
    error = assert_raises(C::InvalidConfig) { C.normalize(BASE.merge(modal: { id: "auth", open: true })) }
    assert_match(/:modal has unknown key :open/, error.message)
    assert_raises(C::InvalidConfig) { C.normalize(BASE.merge(modal: ["auth"])) }
  end

  def test_sign_in_link_takes_only_a_boolean
    assert_equal false, C.normalize(BASE.merge(sign_in_link: false))[:sign_in_link]
    assert_equal true, C.normalize(BASE.merge(sign_in_link: true))[:sign_in_link]
    error = assert_raises(C::InvalidConfig) { C.normalize(BASE.merge(sign_in_link: "no")) }
    assert_match(/:sign_in_link must be true or false/, error.message)
  end

  def test_sign_in_path_is_a_non_blank_plain_string
    path = C.normalize(BASE.merge(sign_in_path: " /signin ".html_safe))[:sign_in_path]

    assert_equal "/signin", path
    refute path.html_safe?, "a host's html_safe flag is dropped"
    assert_raises(C::InvalidConfig) { C.normalize(BASE.merge(sign_in_path: " ")) }
  end

  def test_a_callable_answer_is_checked_with_the_optional_keys
    view = Object.new
    assert_equal({ id: "auth", props: {} }, C.resolve(->(_v) { BASE.merge(modal: "auth") }, view)[:modal])
    assert_raises(C::InvalidConfig) { C.resolve(->(_v) { BASE.merge(modal: { id: "x y" }) }, view) }
  end
end
