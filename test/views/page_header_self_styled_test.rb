# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require "securerandom"
require_relative "../../lib/studio/page_header"
require_relative "../../app/helpers/studio/page_header_helper"

# [unit] The self-styled page header (docs/PAGE_HEADER.md, "In a plain-CSS app") and the
# shared legal page (studio/_legal_page). A plain-CSS app sets
# config.page_header_self_styled, and studio/_page_header then brings its own scoped CSS
# and script, once per page. Off, the row is the same to the byte as a view with no such
# helper at all. How the self-styled row looks and behaves in a browser is
# e2e/page_header_self_styled.spec.js.
class PageHeaderSelfStyledTest < Minitest::Test
  VIEWS = File.expand_path("../../app/views", __dir__)
  ASSETS = File.join(VIEWS, "studio/page_header/_assets.html.erb")

  FULL = {
    title: "Deployments", crumbs: [{ label: "Admin", href: "/admin" }], meta: "v1", meta_title: "version",
    label: "Views", tabs: [{ label: "Deployments", href: "/d", current: "page" }, { label: "Triage", href: "/t" }],
    menu: [{ label: "Stages", href: "/s" }], action: { label: "New Task", href: "/n" },
    tools_html: "<button>Seed</button>", links: [{ label: "Recent", href: "/r", current: "page" }]
  }.freeze

  def setup
    @was = Studio.page_header_self_styled
  end

  def teardown
    Studio.page_header_self_styled = @was
  end

  def new_view(helper: true)
    view = ActionView::Base.with_empty_template_cache.new(ActionView::LookupContext.new([VIEWS]), {}, nil)
    view.extend(Studio::PageHeaderHelper) if helper
    view
  end

  def render_row(view = new_view, **locals)
    locals = FULL.merge(locals)
    locals[:tools_html] = locals[:tools_html].html_safe if locals[:tools_html].is_a?(String)
    view.render(partial: "studio/page_header", locals: locals)
  end

  # The menu's id is random; hold it still so two renders compare.
  def with_fixed_ids
    original = SecureRandom.method(:hex)
    SecureRandom.define_singleton_method(:hex) { |*| "abcd1234" }
    yield
  ensure
    SecureRandom.define_singleton_method(:hex, original)
  end

  def test_off_by_default_the_row_is_the_same_to_the_byte
    Studio.page_header_self_styled = false
    with_fixed_ids do
      with_helper = render_row(new_view(helper: true))
      without = render_row(new_view(helper: false))

      assert_equal without, with_helper
      refute_includes with_helper, "<style"
      refute_includes with_helper, "<script"
    end
  end

  def test_on_the_row_brings_its_styles_and_script_before_the_sentinel
    Studio.page_header_self_styled = true
    doc = Nokogiri::HTML.fragment(render_row)

    assert_equal 1, doc.css("style").size - doc.css("noscript").size, "one stylesheet, beside the noscript fallback"
    assert_equal 1, doc.css("script").size
    first = doc.children.find(&:element?)
    assert_equal "style", first.name, "the assets come first, so the row is styled as it parses"
    assert doc.at_css("style + noscript + script + .page-header-sentinel + div.page-header"),
           "the sentinel keeps the row as its next sibling, which the script and the controller read"
    refute_includes doc.text, "SCOPED CSS", "the partial's comment does not leak into the page"
  end

  # A host with a strict CSP sets a nonce; the row's style and script carry it, so the
  # browser runs them. Without one, neither carries the attribute.
  def test_the_style_and_script_carry_the_requests_csp_nonce
    Studio.page_header_self_styled = true
    view = new_view
    view.define_singleton_method(:content_security_policy_nonce) { "n0nce" }
    doc = Nokogiri::HTML.fragment(render_row(view))

    assert_equal "n0nce", doc.at_css("style")["nonce"]
    assert_equal "n0nce", doc.at_css("script")["nonce"]
    assert_equal "n0nce", Nokogiri::HTML.fragment(render_legal(new_view.tap { |v|
      v.define_singleton_method(:content_security_policy_nonce) { "n0nce" }
    })).at_css("style")["nonce"]
    refute Nokogiri::HTML.fragment(render_row(new_view)).at_css("script").key?("nonce")
  end

  def test_the_assets_render_once_however_many_rows_a_page_has
    Studio.page_header_self_styled = true
    view = new_view
    html = render_row(view) + render_row(view, title: "Second")

    assert_equal 1, html.scan("<script").size
    assert_equal 2, Nokogiri::HTML.fragment(html).css(".page-header-sentinel").size
  end

  def test_a_callable_setting_is_asked_with_the_view
    seen = nil
    Studio.page_header_self_styled = ->(view) { seen = view; false }
    view = new_view
    refute_includes render_row(view), "<style"
    assert_same view, seen

    Studio.page_header_self_styled = ->(_view) { true }
    assert_includes render_row(new_view), "<style"
  end

  def test_self_styled_reads_true_false_and_callables
    assert Studio::PageHeader.self_styled?(nil, true)
    refute Studio::PageHeader.self_styled?(nil, false)
    refute Studio::PageHeader.self_styled?(nil, nil)
    assert Studio::PageHeader.self_styled?(:view, ->(view) { view == :view })
  end

  # Every class the row can emit has a rule in the self-styled sheet, so a class added
  # to the partial and styled only in engine.css fails here, not in a plain app.
  # Two exceptions: the sheet sets position: sticky on .page-header itself, and the
  # action is styled by the .btn classes it also carries.
  def test_the_sheet_styles_every_class_the_row_emits
    Studio.page_header_self_styled = false
    classes = Nokogiri::HTML.fragment(render_row).css("[class]").flat_map { |el| el["class"].split }.uniq
    css = File.read(ASSETS)[%r{<style[^>]*>(.*?)</style>}m, 1]

    missing = (classes - %w[sticky page-header-action]).reject { |name| css.match?(/\.#{Regexp.escape(name)}(?![\w-])/) }
    assert_empty missing, "classes the self-styled sheet does not style"
  end

  # The script reads the theme through custom properties only: no Tailwind class, no
  # .dark selector. Light and dark come from the app's own tokens.
  def test_the_sheet_reads_the_theme_tokens_with_fallbacks
    css = File.read(ASSETS)
    %w[--color-text --color-text-body --color-text-muted --color-surface --color-surface-alt --color-border
       --color-primary --btn-primary-fg].each do |token|
      assert_match(/var\(#{token},/, css, "#{token} is read with a fallback")
    end
    refute_match(/\.dark\b/, css)
  end

  # ---- studio/_legal_page --------------------------------------------------------

  def render_legal(view = new_view, **locals)
    view.render(layout: "studio/legal_page", locals: { title: "Privacy Policy" }.merge(locals)) do
      "<section><h2>1. Who We Are</h2><p>We are us.</p></section>".html_safe
    end
  end

  def test_the_legal_page_is_the_header_and_a_readable_column
    doc = Nokogiri::HTML.fragment(render_legal(updated: "November 8, 2026",
                                               links: [{ label: "Terms of Service", href: "/terms" }],
                                               data: { legal_page: "privacy" }))
    page = doc.at_css("div.legal-page")

    assert page, "the column"
    assert_equal "privacy", page["data-legal-page"]
    assert page.key?("data-studio-legal-page")
    assert_equal ["Privacy Policy"], page.css("h1").map(&:text), "one h1, the header's"
    assert page.at_css(".page-header-sentinel + .page-header h1.page-header-title")
    assert_equal "Last updated November 8, 2026", page.at_css(".legal-page-updated").text.strip
    assert_equal "1. Who We Are", page.at_css("article.legal-page-body > section > h2").text
    assert_equal ["Terms of Service"], page.css(".page-header-links a").map(&:text)
  end

  def test_the_legal_page_prints_no_date_line_without_one_and_styles_once
    view = new_view
    html = render_legal(view) + render_legal(view, title: "Terms of Service")

    refute_includes html, "legal-page-updated\""
    assert_equal 1, html.scan(".legal-page {").size, "the column's styles, once per page"
  end

  def test_the_legal_page_brings_the_row_styles_in_a_self_styled_app
    Studio.page_header_self_styled = true
    html = render_legal

    assert_includes html, ".page-header {"
    assert_includes html, ".legal-page {"
  end
end
