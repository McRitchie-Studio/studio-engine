# frozen_string_literal: true

# [integration] Studio.navbar_name_in_rows through the dummy app: true moves the
# signed-in name out of the account control to the end of row 1 in
# [data-nav-tools], so it stacks over the row-2 slot, as its own control of the
# avatar's kind (a host sidebar button, the link sidebar button, the account
# link, or plain text); the avatar stands alone in [data-nav-account] and takes
# the name as its label. false, the default, keeps the name inside the account
# (the byte baseline, navbar_unset_baseline_test, pins those bytes). Read
# through the HTML5 parser: HTML4 drops @click and :aria-expanded.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require_relative "../support/navbar_render_host"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarNameInRowsRenderTest < ActiveSupport::TestCase
  GEAR = { flag: "gearOpen", controls: %w[gear-sidebar gear-sidebar-mobile] }.freeze
  SECTIONS = [{ title: "Site", links: [{ label: "Home", href: "/", emoji: "*" }] }].freeze

  setup do
    @prior = [Studio.navbar_name_in_rows, Studio.navbar_account_sidebar, Studio.sidebar_sections, Studio.navbar_phone_name]
  end

  teardown do
    Studio.navbar_name_in_rows, Studio.navbar_account_sidebar, Studio.sidebar_sections, Studio.navbar_phone_name = @prior
  end

  test "false, the default, keeps the name inside the account control and out of the rows" do
    Studio.navbar_name_in_rows = false
    page = doc

    assert_equal "Plain User", page.at_css("[data-nav-account] [data-nav-name]")&.text
    assert_nil page.at_css("[data-nav-tools] [data-nav-name]")
    assert_nil page.at_css("[data-nav-name-trigger]")
    assert_nil page.at_css("[data-nav-account]")["aria-label"]
  end

  test "true ends row 1 with the name, after the icons, and leaves the avatar alone in the account" do
    Studio.navbar_name_in_rows = true
    page = doc

    row1 = page.at_css("[data-nav-tools] > div:first-child")
    trigger = row1.element_children.last
    assert trigger.key?("data-nav-name-trigger"), "the name is row 1's last child: #{row1.element_children.map(&:name)}"
    assert_equal "Plain User", trigger.at_css("[data-nav-name]").text
    assert_equal 1, page.css("[data-nav-name]").size, "one name, not two"

    account = page.at_css("[data-nav-account]")
    assert_nil account.at_css("[data-nav-name]")
    assert_equal 1, account.element_children.size, "only the avatar"
    assert_equal "true", account.element_children.first["aria-hidden"]
    assert_equal "Plain User", account["aria-label"], "the avatar control keeps an accessible name"
  end

  test "with a host sidebar, the name is a button that opens what the avatar opens" do
    Studio.navbar_name_in_rows = true
    Studio.navbar_account_sidebar = GEAR
    page = doc
    name = page.at_css("[data-nav-tools] [data-nav-name-trigger]")
    account = page.at_css("[data-nav-account]")

    assert_equal "button", name.name
    assert_equal "button", name["type"]
    %w[aria-controls aria-haspopup @click.stop :aria-expanded].each do |attr|
      refute_nil account[attr], "control: the avatar carries #{attr}"
      assert_equal account[attr], name[attr], attr
    end
    assert name.key?("data-profile-image-toggle"), "a host's capture-phase handler can claim it"
    assert_includes name.at_css("[data-nav-name]")["class"].split, "group-hover:text-primary"
    assert_includes name["class"].split, "group", "the name's hover colour keys on its own control"
    assert_equal "Plain User", account["aria-label"]
  end

  test "with the link sidebar, the name is a button the link sidebar claims" do
    Studio.navbar_name_in_rows = true
    Studio.sidebar_sections = SECTIONS
    name = doc.at_css("[data-nav-tools] [data-nav-name-trigger]")

    assert_equal "button", name.name
    assert_equal "studio-link-sidebar studio-link-sidebar-mobile", name["aria-controls"]
    assert name.key?("data-profile-image-toggle"), "LINK_SIDEBAR_TRIGGERS matches it"
  end

  # A host whose account does not open the link sidebar: the account is a link.
  class LinkHost < NavbarRenderHost
    helper { def studio_account_opens_sidebar? = false }
  end

  test "with neither sidebar, the name links where the avatar links" do
    Studio.navbar_name_in_rows = true
    page = Nokogiri::HTML5(LinkHost.render_navbar(signed_in: true))
    name = page.at_css("[data-nav-tools] [data-nav-name-trigger]")
    account = page.at_css("[data-nav-account]")

    assert_equal "a", name.name
    refute_nil account["href"]
    assert_equal account["href"], name["href"]
  end

  # Carl and Shannon's review: below md the name box is screen-reader text, so
  # a rendered name control there was a 0x0 tab stop that announced the name a
  # second time (the avatar already carries it as its label).
  test "below md the name control is display none unless the phone name is on" do
    Studio.navbar_name_in_rows = true
    Studio.navbar_account_sidebar = GEAR
    Studio.navbar_phone_name = false
    classes = doc.at_css("[data-nav-name-trigger]")["class"].split
    assert_includes classes, "hidden"
    assert_includes classes, "md:block"

    Studio.navbar_phone_name = true
    classes = doc.at_css("[data-nav-name-trigger]")["class"].split
    refute_includes classes, "hidden", "the phone name shows below md, so its control does too"
  end

  test "the phone name setting still shapes the name's box in the rows" do
    Studio.navbar_name_in_rows = true
    Studio.navbar_phone_name = true

    assert doc.at_css("[data-nav-name-trigger] > [data-nav-name-phone] > [data-nav-name]")
  end

  # With the name in row 1 the avatar's box is the account's first child, so
  # the scroll timeline's name scale and nav_collapse's name width must not
  # match it (it would take the name's ratio, not the avatar's).
  test "the timeline's name hooks skip the avatar's aria-hidden box" do
    css = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))
    js = File.read(File.expand_path("../../app/javascript/studio/nav_collapse.js", __dir__))

    assert_includes css, "[data-nav-account] > span:first-child:not([aria-hidden]) { transform-origin: right center; animation-name: nav-tl-name; }"
    refute_match(/\[data-nav-account\] > span:first-child(?!:not\(\[aria-hidden\]\))/, css)
    assert_includes js, "el.querySelector('[data-nav-account] > span:first-child:not([aria-hidden])')"
  end

  test "engine.css spaces the name in row 1 and scales it on the timeline" do
    css = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))
    row = css[/@media \(min-width: 768px\) \{\n      \.nav-shell \{\n        --nav-avatar.*?\n    \}\n/m]

    refute_nil row, "THE ACCOUNT ROW's 768px block"
    assert_includes row, ".nav-shell :has(> [data-nav-tools] [data-nav-name-trigger]) { gap: var(--nav-gap); }"
    assert_includes row, ".nav-shell [data-nav-tools] [data-nav-name-trigger] { margin-inline-start: calc(var(--nav-gap) - 6.3px - 0.5rem); }"
    assert_includes css, ".nav-shell[data-nav-timeline] [data-nav-name-trigger] { transform-origin: right center; animation-name: nav-tl-avatar; }"
  end

  test "only true or false is accepted" do
    assert_raises(ArgumentError) { Studio.navbar_name_in_rows = "yes" }
    assert_raises(ArgumentError) { Studio.navbar_name_in_rows = nil }
  end

  private

  # The name truncates from md, so its control carries the full name as a title
  # for a pointer reader, in every kind the control takes
  # (/tasks/engine-theme-toggle-labels; hosts once patched it in at runtime).
  test "each kind of name control carries the full name as its title" do
    Studio.navbar_name_in_rows = true
    kinds = {}

    Studio.navbar_account_sidebar = GEAR
    kinds[:host_sidebar] = doc.at_css("[data-nav-name-trigger]")
    Studio.navbar_account_sidebar = nil

    Studio.sidebar_sections = SECTIONS
    kinds[:link_sidebar] = doc.at_css("[data-nav-name-trigger]")
    Studio.sidebar_sections = nil

    kinds[:link] = Nokogiri::HTML5(LinkHost.render_navbar(signed_in: true)).at_css("[data-nav-name-trigger]")

    assert_equal %w[button button a], kinds.values.map(&:name), "the three kinds rendered"
    kinds.each { |kind, el| assert_equal "Plain User", el["title"], kind.to_s }
  end

  test "false, the default, adds no title anywhere the name renders" do
    Studio.navbar_name_in_rows = false
    assert_nil doc.at_css("[data-nav-account]")["title"]
  end

  def doc = Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true))
end
