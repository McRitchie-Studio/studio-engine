# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

# [unit] Two views a host's strict script-src (no 'unsafe-inline', a nonce)
# would otherwise refuse:
#
#   - the Phantom callback's inline script carries the request's nonce, and no
#     nonce attribute at all for a host with no nonce generator;
#   - a banner chip carries no inline handler: its hover and focus look is CSS
#     (the [data-studio-banner-button] rule in layouts/studio/_head), read from
#     custom properties on the chip.
class StrictScriptSrcViewsTest < ActiveSupport::TestCase
  GENERATOR = "action_dispatch.content_security_policy_nonce_generator"

  def render_view(env = {}, **options)
    Nokogiri::HTML5(ActionController::Base.renderer.new(env).render(**options))
  end

  def callback(env = {})
    render_view(env, template: "solana_sessions/phantom_callback", layout: false)
  end

  def inline_scripts(doc) = doc.css("script").reject { |script| script["src"] }

  test "the callback's script carries the request nonce" do
    scripts = inline_scripts(callback(GENERATOR => ->(_request) { "callback-nonce" }))

    assert_equal 1, scripts.size
    assert_equal "callback-nonce", scripts.first["nonce"]
  end

  test "with no nonce generator the callback's script has no nonce attribute" do
    scripts = inline_scripts(callback)

    assert_equal 1, scripts.size
    assert_nil scripts.first["nonce"]
  end

  test "a banner chip carries no inline handler, and its hover look as custom properties" do
    [ { label: "Dev", href: "/x", tooltip: "Tip" }, { label: "Go", as: :button }, { label: "On", as: :status },
      { label: "Solid", href: "/y", variant: :solid, hover_background: "#fff7ed" } ].each do |locals|
      chip = render_view(partial: "studio/banners/button", locals: locals).at_css("[data-studio-banner-button]")

      assert chip, "no chip for #{locals}"
      assert_empty chip.attribute_nodes.map(&:name).grep(/\Aon[a-z]+\z/), "inline handler on #{locals}"
      %w[--studio-banner-hover-bg --studio-banner-hover-border --studio-banner-hover-color].each do |property|
        assert_includes chip["style"], "#{property}:", "#{property} missing on #{locals}"
      end
    end
  end

  test "the head styles a banner chip's hover and keyboard focus, tooltip included" do
    head = Studio::Engine.root.join("app/views/layouts/studio/_head.html.erb").read

    assert_includes head, "[data-studio-banner-button]:hover, [data-studio-banner-button]:focus-visible {"
    assert_includes head, "background: var(--studio-banner-hover-bg) !important;"
    assert_includes head, "[data-studio-banner-button]:focus-visible [data-studio-banner-tooltip] { opacity: 1 !important; }"
  end
end
