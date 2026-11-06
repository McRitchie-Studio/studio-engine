# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require "logger"
require "stringio"
require_relative "../../lib/studio/page_header"

# [unit] studio/_page_header's four kinds of right-side control (docs/PAGE_HEADER.md,
# "The four kinds of control"): tabs or anchors, the quick-links menu, the one action
# and the tools, each with its own markup, always in that order. How they look and
# behave in a browser is e2e/page_header_controls.spec.js.
class PageHeaderControlsTest < Minitest::Test
  VIEWS = File.expand_path("../../app/views", __dir__)

  TABS = [{ label: "Deployments", href: "/deployments", current: "page" }, { label: "Triage", href: "/triage" }].freeze
  ANCHORS = [{ label: "Colors", href: "#colors" }, { label: "Buttons", href: "#buttons" }].freeze
  MENU = [{ label: "Stages", href: "/stages" }, { label: "Docs", href: "/docs", data: { test: "docs" } }].freeze
  ACTION = { label: "New Task", href: "/tasks/new", data: { test: "new-task" } }.freeze

  def render_row(**locals)
    view = ActionView::Base.with_empty_template_cache.new(
      ActionView::LookupContext.new([VIEWS]), {}, nil
    )
    Nokogiri::HTML.fragment(view.render(partial: "studio/page_header", locals: { title: "Deployments" }.merge(locals)))
  end

  def kinds_of(doc)
    doc.css(".page-header [data-page-header-kind]").map { |el| el["data-page-header-kind"] }
  end

  def test_tabs_are_one_pill_group_marked_as_tabs
    nav = render_row(label: "Views", tabs: TABS).at_css("nav.page-header-tabs")

    assert_equal "tabs", nav["data-page-header-kind"]
    assert_equal "Views", nav["aria-label"]
    assert_equal %w[Deployments Triage], nav.css(".page-header-tab").map(&:text)
    assert_equal "page", nav.css(".page-header-tab").first["aria-current"]
    nav.css(".page-header-tab").each { |tab| assert_includes tab["class"].split, "btn-sm" }
  end

  # The same pill group: same classes and the gliding pill, only its kind differs. The
  # links are plain same-page hashes, which scroll with no visit.
  def test_anchors_are_the_same_pill_group_with_same_page_links
    doc = render_row(label: "Sections", anchors: ANCHORS)
    nav = doc.at_css("nav.page-header-tabs")

    assert_equal "anchors", nav["data-page-header-kind"]
    assert_equal %w[#colors #buttons], nav.css("a.page-header-tab").map { |a| a["href"] }
    nav.css("a.page-header-tab").each do |a|
      assert_includes a["class"].split, "btn-sm"
      assert_nil a["aria-current"], "no anchor is current until the reader is in its section"
    end
    assert nav.at_css(".page-header-track > .page-header-glide"), "anchors glide as tabs do"
  end

  def test_a_row_takes_tabs_or_anchors_never_both
    error = assert_raises(ActionView::Template::Error) { render_row(label: "x", tabs: TABS, anchors: ANCHORS) }
    assert_match(/tabs: or anchors:, not both/, error.message)
  end

  def test_the_menu_is_one_neutral_button_that_opens_a_list_of_links
    doc = render_row(menu: MENU)
    menu = doc.at_css(".page-header-actions > .page-header-menu")
    button = menu.at_css("button")
    list = menu.at_css("[popover]")

    assert_equal "menu", menu["data-page-header-kind"]
    assert_equal "button", button["type"]
    assert_equal "Links", button.text.strip
    assert_equal %w[btn btn-sm btn-neutral], button["class"].split & %w[btn btn-sm btn-neutral]
    assert_equal list["id"], button["popovertarget"], "the button opens the list with no script"
    assert_equal list["id"], button["aria-controls"]
    assert_match(/\Apage-header-menu-\h{8}\z/, list["id"])
    assert_equal "auto", list["popover"], "auto: Escape and a click outside close it"
    assert_nil list["role"], "a disclosure of links, not an ARIA menu"
    assert_equal %w[Stages Docs], list.css("ul > li > a.page-header-menu-item").map(&:text)
    assert_equal %w[/stages /docs], list.css("a").map { |a| a["href"] }
    assert_equal "docs", list.css("a").last["data-test"]
    assert_equal "true", button.at_css(".page-header-menu-caret")["aria-hidden"]
  end

  def test_menu_label_renames_the_button
    assert_equal "Related", render_row(menu: MENU, menu_label: "Related").at_css(".page-header-menu button").text.strip
  end

  def test_two_menus_on_one_page_never_share_an_id
    ids = 2.times.map { render_row(menu: MENU).at_css("[popover]")["id"] }
    refute_equal ids.first, ids.last
  end

  def test_the_action_is_one_primary_small_button
    action = render_row(action: ACTION).at_css(".page-header-actions > a.page-header-action")

    assert_equal "New Task", action.text
    assert_equal "/tasks/new", action["href"]
    assert_equal %w[btn btn-sm btn-primary], action["class"].split & %w[btn btn-sm btn-primary]
    assert_equal "action", action["data-page-header-kind"]
    assert_equal "new-task", action["data-test"]
  end

  def test_there_is_at_most_one_action
    error = assert_raises(ActionView::Template::Error) { render_row(action: [ACTION, ACTION]) }
    assert_match(/one action/, error.message)
  end

  def test_the_tools_render_after_the_action_in_their_own_muted_slot
    doc = render_row(action: ACTION, tools_html: "<button type='button'>Seed</button>".html_safe)
    tools = doc.at_css(".page-header-actions > .page-header-tools")

    assert_equal "tools", tools["data-page-header-kind"]
    assert_equal "Seed", tools.at_css("button").text
    assert_equal doc.at_css(".page-header-action"), tools.previous_element
  end

  # The fixed order: the pill group, then the menu, then the action, then the tools,
  # whatever order the call names them in.
  def test_the_kinds_render_in_one_fixed_order
    doc = render_row(tools_html: "<span>dev</span>".html_safe, action: ACTION, menu: MENU, label: "Views", tabs: TABS)

    assert_equal %w[tabs menu action tools], kinds_of(doc)
    assert_equal doc.at_css(".page-header-tabs"), doc.at_css(".page-header-actions").previous_element
    assert_equal %w[anchors menu action], kinds_of(render_row(action: ACTION, menu: MENU, label: "S", anchors: ANCHORS))
  end

  def test_every_control_is_the_small_button_size
    doc = render_row(label: "Views", tabs: TABS, menu: MENU, action: ACTION)
    controls = doc.css(".page-header-tab, .page-header-menu-button, .page-header-action")

    assert_equal 4, controls.size
    controls.each { |control| assert_includes control["class"].split, "btn-sm", control.text }
  end

  def test_no_controls_render_no_cluster
    assert_nil render_row.at_css(".page-header-actions")
    assert_nil render_row(menu: [], action: nil, tools_html: "").at_css(".page-header-actions")
  end

  def test_the_deprecated_actions_html_still_renders_before_the_menu
    doc = render_row(actions_html: "<a href='/x' id='old'>Export</a>".html_safe, menu: MENU, action: ACTION)
    cluster = doc.at_css(".page-header-actions")

    assert_equal "old", cluster.element_children.first["id"]
    assert_equal %w[menu action], kinds_of(doc)
  end
end

# The deprecation note: development only, once per call site.
class PageHeaderDeprecationTest < Minitest::Test
  def setup
    Studio::PageHeader.reset_warnings!
    @out = StringIO.new
    @logger = Logger.new(@out)
  end

  def teardown
    Studio::PageHeader.reset_warnings!
  end

  def test_development_warns_once_per_call_site
    assert Studio::PageHeader.deprecate_actions_html(site: "app/views/tasks/_board.html.erb:259", env: "development", logger: @logger)
    refute Studio::PageHeader.deprecate_actions_html(site: "app/views/tasks/_board.html.erb:259", env: "development", logger: @logger)
    assert Studio::PageHeader.deprecate_actions_html(site: "app/views/agents/index.html.erb:19", env: "development", logger: @logger)

    lines = @out.string.lines.grep(/actions_html is deprecated/)
    assert_equal 2, lines.size
    assert_match(%r{Called from app/views/tasks/_board\.html\.erb:259}, lines.first)
    assert_match(/menu:, action: and tools_html:/, lines.first)
    assert_match(/WARN/, lines.first)
  end

  def test_other_environments_say_nothing
    %w[test production staging].each do |env|
      refute Studio::PageHeader.deprecate_actions_html(site: "x:1", env: env, logger: @logger), env
    end
    assert_empty @out.string
  end

  def test_no_logger_says_nothing
    refute Studio::PageHeader.deprecate_actions_html(site: "x:1", env: "development", logger: nil)
  end

  # Rendered with actions_html in development, the partial writes the note once,
  # naming the call site. The partial reads Rails' env and logger, so a stand-in Rails
  # supplies them for this one test.
  def test_the_partial_writes_the_note_when_actions_html_is_passed_in_development
    with_rails(env: "development", logger: @logger) do
      view = ActionView::Base.with_empty_template_cache.new(
        ActionView::LookupContext.new([PageHeaderControlsTest::VIEWS]), {}, nil
      )
      view.render(partial: "studio/page_header", locals: { title: "A", action: { label: "New", href: "/n" } })
      assert_empty @out.string, "a render with no actions_html says nothing"
      view.render(partial: "studio/page_header", locals: { title: "A", actions_html: "<a>x</a>".html_safe })
    end

    assert_equal 1, @out.string.lines.grep(/actions_html is deprecated/).size
  end

  private

  def with_rails(env:, logger:)
    had = defined?(::Rails)
    unless had
      Object.const_set(:Rails, Module.new)
    end
    rails = ::Rails
    saved = %i[env logger].to_h { |name| [name, rails.respond_to?(name) ? rails.method(name) : nil] }
    rails.define_singleton_method(:env) { env }
    rails.define_singleton_method(:logger) { logger }
    yield
  ensure
    if had
      saved.each { |name, original| original ? rails.define_singleton_method(name, original) : rails.singleton_class.send(:remove_method, name) }
    else
      Object.send(:remove_const, :Rails)
    end
  end
end
