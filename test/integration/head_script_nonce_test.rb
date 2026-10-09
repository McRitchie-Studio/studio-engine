# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "nokogiri"

# [integration] Every inline script the engine's head renders carries the
# request's CSP nonce.
#
# The head's behaviour lives in ES modules (app/javascript/studio), booted by
# studio/application. What is left inline is the pre-paint theme script, the
# hold button's guard (studio/_hold_button_guard), the import map, the module tag
# that imports the boot, and the ones that import a module by its own door (so a
# failed boot keeps the stores, the hold button and the rest); each carries the nonce,
# so a host whose policy names a nonce (and so ignores 'unsafe-inline') still
# runs all of them. A new inline <script> in the head without the nonce fails
# here.
#
# The dummy host sets no nonce generator, so the test installs one where a host's
# config.content_security_policy_nonce_generator lands: the application's
# env_config, which Rails merges into every request (and which therefore
# overwrites the same key passed per request).
class HeadScriptNonceTest < ActionDispatch::IntegrationTest
  NONCE = "head-nonce-probe"
  GENERATOR = ->(_request) { NONCE }
  KEY = "action_dispatch.content_security_policy_nonce_generator"

  setup do
    @previous_generator = Rails.application.env_config[KEY]
    Rails.application.env_config[KEY] = GENERATOR
  end

  teardown { Rails.application.env_config[KEY] = @previous_generator }

  def head_scripts(path)
    get path
    assert_response :success
    Nokogiri::HTML(response.body).css("head script")
  end

  test "the head's inline scripts all carry the request nonce" do
    inline = head_scripts("/lab/bar_stack").reject { |script| script["src"] }

    refute_empty inline, "found no inline script in the head, so this proves nothing"
    inline.each do |script|
      assert_equal NONCE, script["nonce"],
                   "inline <script#{" type=#{script['type']}" if script['type']}> has no nonce:\n#{script.text.strip[0, 200]}"
    end
  end

  test "what stays inline is the pre-paint theme, the hold button guard, the import map, the boot import and the five own-door imports" do
    inline = head_scripts("/lab/bar_stack").reject { |script| script["src"] }

    assert_equal 9, inline.size, "the head's inline scripts:\n#{inline.map { |s| s.to_html[0, 120] }.join("\n")}"
    assert_includes inline[0].text, "classList.add('dark')", "the pre-paint theme script comes first"
    assert_includes inline[1].text, "studioHoldButtonGuard", "the hold button's guard comes second"
    assert_equal "importmap", inline[2]["type"]
    assert_equal "module", inline[3]["type"]
    assert_equal %(import "studio/application"), inline[3].text.strip
    assert_equal %w[studio/stimulus studio/alpine_stores studio/modal_host studio/toast studio/link_sidebar],
                 inline[4..].map { |script| script.text.strip[/\Aimport "([^"]+)"\z/, 1] }
    assert_equal %w[module] * 5, inline[4..].map { |script| script["type"] }
  end

  # The guard reports a hold button whose modules failed to load, so it is a
  # classic inline script that imports nothing: nonced, so a strict policy runs
  # it, and ahead of every module tag, so no module's failure can precede it.
  test "the hold button's guard is a nonced classic inline script, before every module" do
    scripts = head_scripts("/lab/bar_stack")
    guards = scripts.select { |script| script.text.include?("studioHoldButtonGuard") }

    assert_equal 1, guards.size, "the head renders the guard once"
    guard = guards.first
    assert_equal NONCE, guard["nonce"]
    assert_nil guard["type"], "a module script would wait behind the modules it reports on"
    assert_nil guard["src"], "a request of its own is one more that can fail"
    refute_match(/\bimport\s*[("'{*]/, guard.text, "the guard imports a module")

    first_module = scripts.index { |script| %w[module importmap].include?(script["type"]) }
    assert_operator scripts.index(guard), :<, first_module
  end

  test "with no nonce generator the guard renders without a nonce attribute" do
    Rails.application.env_config[KEY] = nil
    guard = head_scripts("/lab/bar_stack").find { |script| script.text.include?("studioHoldButtonGuard") }

    refute_nil guard
    refute guard.key?("nonce")
  end

  # The Stimulus application's own door: the hold button confirms real actions,
  # so it is imported here and must not depend on the rest of the boot's graph.
  test "the Stimulus application loads by its own nonced module tag" do
    scripts = head_scripts("/lab/bar_stack")
    stimulus = scripts.index { |script| script.text.strip == %(import "studio/stimulus") }

    refute_nil stimulus, "the head does not import studio/stimulus by its own tag"
    assert_equal NONCE, scripts[stimulus]["nonce"]
    assert_equal "module", scripts[stimulus]["type"]

    source = File.read(File.expand_path("../../app/javascript/studio/stimulus.js", __dir__))
    imports = source.scan(/^import\s.*?from\s+"([^"]+)"/).flatten
    assert_equal %w[@hotwired/stimulus studio/lazy_controllers studio/controllers/hold_button_controller], imports,
                 "anything more it imports is one more file whose failure takes the hold button down"
  end

  # The link sidebar's own door: components/_link_sidebar binds
  # $store.sidebars.linkTreeOpen, so a failed boot must not take the flag or the
  # click handlers with it.
  test "the link sidebar's flag loads by its own nonced module tag, before Alpine" do
    scripts = head_scripts("/lab/bar_stack")
    sidebar = scripts.index { |script| script.text.strip == %(import "studio/link_sidebar") }
    alpine = scripts.index { |script| script["src"].to_s.include?("studio/alpine") }

    refute_nil sidebar, "the head does not import studio/link_sidebar by its own tag"
    assert_equal NONCE, scripts[sidebar]["nonce"]
    assert_equal "module", scripts[sidebar]["type"]
    assert_operator sidebar, :<, alpine, "the flag's listener must be registered before Alpine starts"
  end

  # The toast queue's own door: layouts/studio/_flash binds $store.toasts, so a
  # failed boot must not take the store, the flash or the `toast` event with it.
  test "the toast queue loads by its own nonced module tag, before Alpine" do
    scripts = head_scripts("/lab/bar_stack")
    toast = scripts.index { |script| script.text.strip == %(import "studio/toast") }
    alpine = scripts.index { |script| script["src"].to_s.include?("studio/alpine") }

    refute_nil toast, "the head does not import studio/toast by its own tag"
    assert_equal NONCE, scripts[toast]["nonce"]
    assert_equal "module", scripts[toast]["type"]
    assert_operator toast, :<, alpine, "the toast store's listener must be registered before Alpine starts"
  end

  # The modal stack's own door, for the same reason as the stores': a host's
  # template binds $store.modals.current(), so a failed boot must not take it.
  test "the modal stack loads by its own nonced module tag, before Alpine" do
    scripts = head_scripts("/lab/bar_stack")
    modals = scripts.index { |script| script.text.strip == %(import "studio/modal_host") }
    alpine = scripts.index { |script| script["src"].to_s.include?("studio/alpine") }

    refute_nil modals, "the head does not import studio/modal_host by its own tag"
    assert_equal NONCE, scripts[modals]["nonce"]
    assert_equal "module", scripts[modals]["type"]
    assert_operator modals, :<, alpine, "the modal stores' listener must be registered before Alpine starts"
  end

  # The stores' own door. Its own tag, not a line inside the boot import, so a
  # boot module that fails to load cannot take it down; nonced like the rest;
  # and before Alpine, so the alpine:init listener is in place when Alpine fires it.
  test "the Alpine stores load by their own nonced module tag, before Alpine" do
    scripts = head_scripts("/lab/bar_stack")
    stores = scripts.index { |script| script.text.strip == %(import "studio/alpine_stores") }
    alpine = scripts.index { |script| script["src"].to_s.include?("studio/alpine") }

    refute_nil stores, "the head does not import studio/alpine_stores by its own tag"
    assert_equal NONCE, scripts[stores]["nonce"]
    assert_equal "module", scripts[stores]["type"]
    assert_operator stores, :<, alpine, "the stores' listener must be registered before Alpine starts"
  end

  test "Alpine loads after the boot import, so its shims exist before Alpine starts" do
    scripts = head_scripts("/lab/bar_stack")
    boot = scripts.index { |script| script.text.include?(%(import "studio/application")) }
    alpine = scripts.index { |script| script["src"].to_s.include?("studio/alpine") }

    refute_nil boot, "the head does not import studio/application"
    refute_nil alpine, "the head does not load Alpine"
    assert_operator boot, :<, alpine, "Alpine must come after the module tags"
    assert scripts[alpine].key?("defer"), "Alpine must stay deferred, or it runs before the modules"
  end
end
