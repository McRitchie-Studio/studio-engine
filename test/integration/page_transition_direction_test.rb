# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

# [integration] Studio.page_transition_direction against the REAL lib/studio.rb (the
# test_helper mirror does not validate), and the lab route the browser lane drives.
class PageTransitionDirectionTest < ActionDispatch::IntegrationTest
  teardown do
    Studio.page_transition_direction = nil
    Studio.page_transition_style = nil
  end

  test "the writer takes the four directions, as a symbol or a string, and nil" do
    %i[left right top bottom].each do |direction|
      Studio.page_transition_direction = direction
      assert_equal direction, Studio.page_transition_direction
    end
    Studio.page_transition_direction = "top"
    assert_equal :top, Studio.page_transition_direction
    Studio.page_transition_direction = nil
    assert_nil Studio.page_transition_direction
  end

  test "the writer refuses a typo at boot" do
    error = assert_raises(ArgumentError) { Studio.page_transition_direction = :diagonal }
    assert_includes error.message, "left, right, top, bottom"
  end

  test "the style writer takes the two styles, as a symbol or a string, and nil is the default" do
    %i[slide unfold].each do |style|
      Studio.page_transition_style = style
      assert_equal style, Studio.page_transition_style
    end
    Studio.page_transition_style = "unfold"
    assert_equal :unfold, Studio.page_transition_style
    Studio.page_transition_style = nil
    assert_equal :slide, Studio.page_transition_style
  end

  test "an absent style is the slide, never a draw" do
    assert_equal :slide, Studio.page_transition_style
    get "/lab/page_transitions?direction=left"
    assert_includes response.body, '<meta name="page-transition-style" content="slide">'
  end

  test "the style writer refuses a typo at boot" do
    error = assert_raises(ArgumentError) { Studio.page_transition_style = :fade }
    assert_includes error.message, "slide, unfold"
  end

  test "the style renders only with a direction" do
    Studio.page_transition_style = :unfold
    get "/lab/page_transitions"
    refute_includes response.body, "page-transition-style"

    get "/lab/page_transitions?direction=right"
    assert_includes response.body, '<meta name="page-transition-style" content="unfold">'
  end

  test "a set direction renders the metas and the module tag; none renders neither" do
    get "/lab/page_transitions"
    assert_response :success
    refute_includes response.body, "page-transition-direction"
    refute_includes response.body, 'import "studio/page_transitions"'
    refute_includes response.body, "vt-pinned-header"

    get "/lab/page_transitions?direction=right"
    assert_includes response.body, '<meta name="page-transition-direction" content="right">'
    assert_includes response.body, '<meta name="view-transition" content="same-origin">'
    assert_includes response.body, 'import "studio/page_transitions"'
    assert_equal 1, response.body.scan("vt-pinned-header").size
  end

  test "the full-load sheet and script render only with a direction" do
    get "/lab/page_transitions"
    refute_includes response.body, "page_transition_full_load"
    refute_includes response.body, "page_transition_reveal"

    get "/lab/page_transitions?direction=right"
    assert_includes response.body, "/e2e/css/studio/page_transition_full_load.css"
    assert_includes response.body, "/e2e/js/studio/page_transition_reveal.js"
  end

  test "the classic script is not a module, so a host with no direction gets no new import map entry" do
    refute_includes Studio::Engine.javascript_module_logical_paths, "studio/page_transition_reveal.js"
    get "/lab/page_transitions"
    refute_includes response.body[/<script type="importmap".*?<\/script>/m], "page_transition_reveal"
  end

  test "a strict page's script carries the nonce its header names, and the header adds no unsafe-inline" do
    get "/lab/page_transitions?direction=left&strict=1"
    policy = response.headers["Content-Security-Policy"]
    script_src = policy[/script-src [^;]+/]
    refute_includes script_src, "unsafe-inline"

    script = Nokogiri::HTML(response.body).at_css('head script[src*="page_transition_reveal"]')
    assert script, "no reveal script in the head"
    assert_includes script_src, "'nonce-#{script['nonce']}'"
    Nokogiri::HTML(response.body).css("head script").reject { |tag| tag["src"] }.each do |inline|
      assert_includes script_src, "'nonce-#{inline['nonce']}'", "an inline head script has no nonce:\n#{inline.text[0, 100]}"
    end
  end

  test "the at-rule that takes no selector is in the named sheet alone, behind reduced motion" do
    root = File.expand_path("../..", __dir__)
    sheet = File.read(File.join(root, "app/assets/stylesheets/studio/page_transition_full_load.css"))
    assert_match(/@media \(prefers-reduced-motion: no-preference\) \{\s*@view-transition \{\s*navigation: auto;/, sheet)
    refute_includes File.read(File.join(root, "app/assets/tailwind/studio_engine/engine.css")), "@view-transition"
    assert_includes Rails.application.config.assets.precompile, "studio/page_transition_full_load.css" if Rails.application.config.respond_to?(:assets)
    engine = File.read(File.join(root, "lib/studio/engine.rb"))
    assert_includes engine, "studio/page_transition_full_load.css"
    assert_includes engine, "studio/page_transition_reveal.js"
  end

  test "the engine chat's morph markers render only with a direction" do
    get "/agent_chat_lab"
    assert_response :success
    assert_includes response.body, "view-transition-name: agent-portrait"
    refute_includes response.body, "data-vt-morph"

    Studio.page_transition_direction = :left
    get "/agent_chat_lab"
    assert_includes response.body, 'data-vt-morph="agent-portrait"'
    assert_includes response.body, 'data-vt-morph="agent-composer"'
  end

  test "the module is pinned for a host, and not preloaded on every page" do
    refute_includes Studio::Engine.javascript_boot_graph, "studio/page_transitions"
    assert_includes Studio::Engine.javascript_module_logical_paths, "studio/page_transitions.js"
  end
end
