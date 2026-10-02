# frozen_string_literal: true

# Renders the engine's own auth pages through the dummy app and pins
# Studio.sign_in_label on them: /login (password, magic-link and SSO variants),
# /signup, and the magic-link confirm interstitial. An app that configures
# "Sign in" sees "Sign in" on every one of them and no "Log in"; an app that
# configures nothing renders the pre-feature bytes. Wording rules:
# lib/studio/auth_labels.rb.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "active_model"
require "nokogiri"

class AuthPageLabelsHostController < ActionController::Base
  helper_method :sso_user_available?, :sso_hub_logo, :sso_source_app, :sso_display_name,
                :magic_link_request_path

  # The sign-up form's model: only what form_with and the template read.
  class SignupUser
    include ActiveModel::Model

    attr_accessor :name, :email, :password, :password_confirmation

    def self.model_name = ActiveModel::Name.new(self, nil, "User")
  end

  class_attribute :sso, default: false

  def sso_user_available? = sso
  def sso_hub_logo = nil
  def sso_source_app = "Hub"
  def sso_display_name = "Pat"

  # The dummy draws its routes before any test enables :magic_link, so the
  # request route's helper is not drawn; the form only needs its path.
  def magic_link_request_path = "/magic_link"
end

class AuthPageLabelsRenderTest < ActiveSupport::TestCase
  # Each auth page's label-bearing markup exactly as it rendered before the
  # label reached these pages. The default must keep printing every one.
  PRE_FEATURE = {
    login: [
      %(<p class="text-secondary mt-2">Log in to continue</p>),
      %(<button type="submit" class="btn btn-primary btn-lg w-full">\n            Log In\n          </button>)
    ],
    magic_link_login: [
      %(<button type="submit" class="btn btn-primary btn-lg w-full">\n            Send sign-in link\n          </button>)
    ],
    sso_login: [
      %(<span class="text-muted text-xs uppercase tracking-wider">or sign in below</span>)
    ],
    signup: [
      %(Already have an account?\n        <a class="text-primary hover:text-primary-300 font-medium underline underline-offset-2" href="/login">Log in</a>)
    ],
    interstitial: [
      %(<button class="magic-submit" type="submit">\n          Sign in to Dummy\n</button>)
    ]
  }.freeze

  setup do
    @prior_label = Studio.sign_in_label
    @prior_auth = Studio.auth_methods
    @prior_app_name = Studio.app_name
    Studio.app_name = "Dummy"
    AuthPageLabelsHostController.sso = false
    define_user(authenticate: true)
  end

  teardown do
    Studio.sign_in_label = @prior_label
    Studio.auth_methods = @prior_auth
    Studio.app_name = @prior_app_name
    remove_user_const
  end

  test "an app that configures no label renders every auth page's pre-feature text" do
    assert_equal "Log in", Studio.sign_in_label

    pages.each do |page, html|
      PRE_FEATURE.fetch(page).each { |snippet| assert_includes html, snippet, "#{page} lost its default wording" }
    end
  end

  test "configuring the label changes those words and no other byte" do
    defaults = pages
    Studio.sign_in_label = "Log on"
    configured = pages

    # "Log on" differs from every default form, so each derived word is visible.
    swaps = {
      login: { "Log on to continue" => "Log in to continue", "Log On\n" => "Log In\n" },
      magic_link_login: { "Send log-on link" => "Send sign-in link", "Log on to continue" => "Log in to continue" },
      sso_login: { "or log on below" => "or sign in below", "Log on to continue" => "Log in to continue",
                   "Log On\n" => "Log In\n" },
      signup: { ">Log on</a>" => ">Log in</a>" },
      interstitial: { "Log on to Dummy" => "Sign in to Dummy" }
    }

    defaults.each do |page, html|
      restored = swaps.fetch(page).reduce(configured.fetch(page)) do |text, (now, before)|
        assert_includes text, now, "#{page} does not say #{now.inspect}"
        text.gsub(now, before)
      end
      assert_equal html, restored, "#{page} changed more than its sign-in words"
    end
  end

  test "Sign in reaches the login, sign-up and magic-link pages, and no Log in remains" do
    Studio.sign_in_label = "Sign in"

    pages.each do |page, html|
      refute_match(/log[ -]?in/i, visible_text(html), "#{page} still says Log in")
    end

    login = Nokogiri::HTML(pages.fetch(:login))
    assert_equal "Sign in to continue", login.at_css("p.text-secondary").text
    assert_equal "Sign In", login.at_css("button[type=submit]").text.strip

    assert_equal "Send sign-in link", Nokogiri::HTML(pages.fetch(:magic_link_login)).at_css("button[type=submit]").text.strip
    assert_includes visible_text(pages.fetch(:sso_login)), "or sign in below"
    assert_equal "Sign in", Nokogiri::HTML(pages.fetch(:signup)).at_css("a[href='/login']").text
    assert_equal "Sign in to Dummy", Nokogiri::HTML(pages.fetch(:interstitial)).at_css("button.magic-submit").text.strip
  end

  test "a configured label is escaped on every page" do
    Studio.sign_in_label = "<b>Go</b>"

    pages.each do |page, html|
      refute_includes html, "<b>", "#{page} printed the label raw"
    end
  end

  private

  def pages
    {
      login: render_login(auth: %i[password google]),
      magic_link_login: render_login(auth: %i[magic_link google], password_user: false),
      sso_login: render_login(auth: %i[password], sso: true),
      signup: render_page(template: "registrations/new", assigns: { user: AuthPageLabelsHostController::SignupUser.new }),
      interstitial: render_page(partial: "studio/confirm_interstitial", locals: { consume_path: "/l/tok/consume" })
    }
  end

  def render_login(auth:, password_user: true, sso: false)
    Studio.auth_methods = auth
    password_user ? define_user(authenticate: true) : remove_user_const
    AuthPageLabelsHostController.sso = sso
    render_page(template: "sessions/new")
  ensure
    AuthPageLabelsHostController.sso = false
  end

  def render_page(**options)
    AuthPageLabelsHostController.render(**options, layout: false)
  end

  def visible_text(html)
    Nokogiri::HTML(html).css("body").text
  end

  def define_user(authenticate:)
    remove_user_const
    klass = Class.new
    klass.define_method(:authenticate) { |_password| true } if authenticate
    Object.const_set(:User, klass)
  end

  def remove_user_const
    Object.send(:remove_const, :User) if Object.const_defined?(:User, false)
  end
end
