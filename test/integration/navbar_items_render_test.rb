# frozen_string_literal: true

# Renders the engine navbar through the dummy app and pins Studio.navbar_items:
# registered partials land after the navbar_links in the desktop bar AND the
# phone row, locals reach them, a raising callable renders nothing, and an app
# that registers nothing gets the navbar's pre-feature bytes.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarItemsRenderHostController < ActionController::Base
  prepend_view_path File.expand_path("../views/fixtures", __dir__)
  helper_method :logged_in?, :root_path, :geo?

  def logged_in? = false
  def root_path = "/"
  def geo? = true
end

class NavbarItemsRenderTest < ActiveSupport::TestCase
  # The slots exactly as the navbar rendered them before navbar_items existed
  # (navbar_links_render_test pins the same two).
  EMPTY_DESKTOP_SLOT = %(<nav class="hidden md:flex items-center gap-4">\n        </nav>)
  EMPTY_PHONE_ROW_OPEN = %(bg-surface-alt">\n    <span class="ml-auto)

  ITEMS = ["navbar_slot_fixtures/geo",
           { partial: "navbar_slot_fixtures/wallet", locals: { tone: "muted" } }].freeze
  LINKS = [{ label: "Contests", href: "/contests" }].freeze

  setup do
    @prior_items = Studio.navbar_items
    @prior_links = Studio.navbar_links
  end

  teardown do
    Studio.navbar_items = @prior_items
    Studio.navbar_links = @prior_links
  end

  test "nothing registered renders the pre-feature slots" do
    Studio.navbar_items = []
    html = render_navbar

    assert_includes html, EMPTY_DESKTOP_SLOT
    assert_includes html, EMPTY_PHONE_ROW_OPEN
    refute_includes html, "data-slot-item"
  end

  test "an empty or nil-answering callable renders the same bytes as the empty default" do
    Studio.navbar_items = []
    empty = render_navbar

    Studio.navbar_items = ->(_view) { [] }
    assert_equal empty, render_navbar
    Studio.navbar_items = ->(_view) {}
    assert_equal empty, render_navbar
  end

  test "items render after the links in both the desktop bar and the phone row" do
    Studio.navbar_links = LINKS
    Studio.navbar_items = ITEMS
    doc = Nokogiri::HTML(render_navbar)

    desktop = doc.at_css("nav.hidden.md\\:flex")
    phone_row = doc.at_css("header > div.md\\:hidden")

    assert_equal %w[a geo wallet], slot_order(desktop.element_children)
    assert_equal %w[nav geo wallet span], slot_order(phone_row.element_children),
                 "in the phone row, after the links and before the right-hand controls"
  end

  test "items render with no links registered too" do
    Studio.navbar_links = []
    Studio.navbar_items = ["navbar_slot_fixtures/geo"]
    doc = Nokogiri::HTML(render_navbar)

    assert_equal 2, doc.css("[data-slot-item=geo]").size, "one per row"
    assert_equal %w[geo span], slot_order(doc.at_css("header > div.md\\:hidden").element_children)
  end

  test "a hash spec's locals reach the partial, and the callable reads the view" do
    Studio.navbar_items = ->(view) { view.geo? ? ITEMS : [] }
    doc = Nokogiri::HTML(render_navbar)

    assert_equal %w[muted muted], doc.css("[data-slot-item=wallet]").map { |el| el["data-tone"] }
  end

  test "preview renders carry the items, as they carry the links" do
    Studio.navbar_links = LINKS
    Studio.navbar_items = ITEMS
    doc = Nokogiri::HTML(render_navbar(preview: true))

    assert_equal 2, doc.css("[data-slot-item=geo]").size
    assert_equal 2, doc.css("nav a[href='/contests']").size
  end

  test "a raising callable renders nothing in place of the items, never a 500" do
    Studio.navbar_items = []
    empty = render_navbar
    Studio.navbar_items = ->(_view) { raise KeyError, "no geo" }

    assert_equal empty, render_navbar
  end

  test "a bad static list is refused when assigned, before any render" do
    error = assert_raises(Studio::NavbarSlots::InvalidConfig) do
      Studio.navbar_items = ["navbar_slot_fixtures/geo", { locals: {} }]
    end

    assert_match(/navbar_items\[1\].*:partial/, error.message)
    assert_raises(Studio::NavbarSlots::InvalidConfig) { Studio.navbar_items = "navbar_slot_fixtures/geo" }
  end

  private

  def slot_order(elements)
    elements.map { |el| el["data-slot-item"] || el.name }
  end

  def render_navbar(path: "/", preview: false)
    controller = NavbarItemsRenderHostController.new
    controller.request = ActionDispatch::TestRequest.create("PATH_INFO" => path)
    controller.response = ActionDispatch::TestResponse.new
    controller.render_to_string(inline: %(<%= render "layouts/navbar", preview: #{preview} %>))
  end
end
