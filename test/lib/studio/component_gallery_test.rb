# frozen_string_literal: true

require "test_helper"
require "studio/component_gallery"

# [unit] Studio::ComponentGallery: where the gallery is drawn, and who the
# router lets in. The requests and users are stand-ins; the real session and
# User are exercised in test/integration/component_gallery_test.rb.
class StudioComponentGalleryTest < Minitest::Test
  Request = Struct.new(:session)

  class FakeUser
    attr_reader :session_token

    def initialize(admin:, session_token: :none)
      @admin = admin
      @session_token = session_token
      singleton_class.send(:undef_method, :session_token) if session_token == :none
    end

    def admin? = @admin
  end

  def with_users(users)
    finder = Object.new
    finder.define_singleton_method(:find_by) { |id:| users[id] }
    Object.const_set(:User, finder)
    yield
  ensure
    Object.send(:remove_const, :User) if Object.const_defined?(:User, false)
  end

  def admin_request?(session)
    Studio::ComponentGallery.admin_request?(Request.new(session))
  end

  def mounted?(env, in_production, lookbook_loaded: true)
    Studio::ComponentGallery.mounted?(env: env, in_production: in_production, lookbook_loaded: lookbook_loaded)
  end

  def test_drawn_in_development_and_test_whatever_the_flag
    %w[development test].each do |env|
      assert mounted?(env, false), env
      assert mounted?(env, true), env
    end
  end

  def test_drawn_in_production_only_when_the_app_opts_in
    refute mounted?("production", false)
    refute mounted?("production", nil)
    refute mounted?("production", "true"), "only true opts in, not a truthy string from an env var"
    assert mounted?("production", true)
  end

  def test_never_drawn_when_the_bundle_has_no_lookbook
    %w[development test production].each do |env|
      refute mounted?(env, true, lookbook_loaded: false), env
    end
  end

  def test_the_load_order_is_ok_unless_lookbook_came_first
    original = Studio::ComponentGallery.lookbook_loaded_before_engine
    Studio::ComponentGallery.lookbook_loaded_before_engine = false
    assert Studio::ComponentGallery.load_order_ok?
    Studio::ComponentGallery.lookbook_loaded_before_engine = true
    refute Studio::ComponentGallery.load_order_ok?
  ensure
    Studio::ComponentGallery.lookbook_loaded_before_engine = original
  end

  def test_an_admin_with_a_matching_token_is_let_in
    with_users(7 => FakeUser.new(admin: true, session_token: "abc")) do
      assert admin_request?(Studio.session_key => 7, :session_token => "abc")
      assert admin_request?(Studio.session_key.to_s => 7, :session_token => "abc"), "a string session key"
    end
  end

  def test_an_admin_on_a_user_with_no_token_column_is_let_in
    with_users(7 => FakeUser.new(admin: true)) do
      assert admin_request?(Studio.session_key => 7)
    end
  end

  def test_everyone_else_is_refused
    users = {
      7 => FakeUser.new(admin: true, session_token: "abc"),
      8 => FakeUser.new(admin: false, session_token: "def"),
      9 => FakeUser.new(admin: true, session_token: "")
    }
    with_users(users) do
      refute admin_request?({}), "a visitor"
      refute admin_request?(Studio.session_key => 404), "a session for a deleted user"
      refute admin_request?(Studio.session_key => 8, :session_token => "def"), "a non-admin"
      refute admin_request?(Studio.session_key => 7, :session_token => "stale"), "a rotated token"
      refute admin_request?(Studio.session_key => 7), "no token in the cookie"
      refute admin_request?(Studio.session_key => 9, :session_token => ""), "a blank token on both sides"
    end
  end

  def test_no_user_model_refuses
    refute Object.const_defined?(:User, false)
    refute admin_request?(Studio.session_key => 7)
  end

  def test_the_lookbook_settings_keep_the_gallery_to_output
    config = ActiveSupport::OrderedOptions.new
    config.preview_inspector = ActiveSupport::OrderedOptions.new
    config.preview_embeds = ActiveSupport::OrderedOptions.new
    Studio::ComponentGallery.configure_lookbook!(config)

    assert_equal %i[preview output], config.preview_inspector.main_panels
    assert_equal %i[notes], config.preview_inspector.drawer_panels
    assert_equal false, config.preview_embeds.enabled
    assert_equal [], config.page_paths
    assert_equal false, config.live_updates
    assert_equal true, config.lazy_load_previews_and_pages
  end
end
