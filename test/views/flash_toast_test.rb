# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require "json"

# Renders layouts/studio/_flash through ActionView and pins what a page hands
# studio/toast: one root on the engine's toast controller, the request's notice
# and alert as its JSON value, bindings on $store.toasts, and no script of its own.
class FlashToastTest < Minitest::Test
  def test_the_root_carries_the_controller_and_the_flash_as_json
    root = root_for(notice: "Saved", alert: %(Can't "do" that <now>))

    assert_equal "toast", root["data-studio-controller"]
    assert root.key?("x-data"), "the bindings below need an Alpine scope"
    assert_equal "", root["x-data"].to_s, "the scope is bare: the queue is $store.toasts"
    assert_equal [{ "type" => "notice", "message" => "Saved" },
                  { "type" => "alert", "message" => %(Can't "do" that <now>) }],
                 JSON.parse(root["data-toast-initial-value"])
  end

  def test_other_flash_keys_are_not_toasts
    root = root_for(notice: "Saved", analytics: "signed_up")

    assert_equal [{ "type" => "notice", "message" => "Saved" }], JSON.parse(root["data-toast-initial-value"])
  end

  def test_no_flash_is_an_empty_list
    assert_equal [], JSON.parse(root_for({})["data-toast-initial-value"])
  end

  def test_the_partial_emits_no_script_and_binds_the_store
    html = render_flash(notice: "Saved")
    doc = Nokogiri::HTML5.fragment(html)

    refute_match(/<script/i, html, "the queue is studio/toast, a nonced module")
    refute_includes html, "toastManager"
    assert_equal "(toast, index) in $store.toasts.toasts", doc.at_css("#toast-container > template")["x-for"]
    assert_equal "$store.toasts.dismiss(toast.id)", doc.at_css('button[aria-label="Dismiss"]')["@click.stop"]
  end

  private

  def root_for(flash) = Nokogiri::HTML5.fragment(render_flash(flash)).at_css("[data-studio-controller]")

  def render_flash(flash)
    view_path = File.expand_path("../../app/views", __dir__)
    lookup = ActionView::LookupContext.new([view_path])
    view = ActionView::Base.with_empty_template_cache.new(lookup, {}, nil)
    messages = flash.transform_keys(&:to_s)
    view.define_singleton_method(:flash) { messages }
    view.render(partial: "layouts/studio/flash")
  end
end
