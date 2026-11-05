# frozen_string_literal: true

require "test_helper"
require "action_view"
require "action_dispatch"
require "nokogiri"

# [unit] The shared head sends no `Link: rel=modulepreload` response header.
#
# javascript_include_tag "x", type: "module" sends one by default
# (config.action_view.preload_links_header, on in every host). Firefox reads the
# header before it parses the body, so a module preload has started by the time it
# reaches the head's import map, and it refuses the map: "Import maps are not allowed
# after a module load or preload has started". Every bare `studio/*` import on the
# page then fails, and no panel opens. Chrome accepts the map, so only Firefox shows
# it (926c340, 2026-10-26; found by Carl on three production hosts, 2026-11-05).
#
# This renders the head through Rails' real helper, not the lab's stand-in, and reads
# the header off a real response.
class HeadSendsNoModulePreloadTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  INCLUDE_TAG = /javascript_include_tag\b(?:(?!%>).)*%>/m
  PRELOAD_SETTING = ActionView::Helpers::AssetTagHelper
  FakeController = Struct.new(:response, :request)

  def setup
    @preload_links_header = PRELOAD_SETTING.preload_links_header
    @sticky_table_headers = Studio.sticky_table_headers
    PRELOAD_SETTING.preload_links_header = true
    Studio.sticky_table_headers = true
  end

  def teardown
    PRELOAD_SETTING.preload_links_header = @preload_links_header
    Studio.sticky_table_headers = @sticky_table_headers
  end

  def test_the_head_sends_no_modulepreload_header
    html, link = render_head

    assert_includes html, "studio/alpine", "the head rendered no Alpine, so this proves nothing"
    assert_includes html, "studio/sticky_table_header", "the head rendered no sticky module, so this proves nothing"
    refute_includes link, "modulepreload"
  end

  # The harness bites: the same helper on the same response, with the tag the head
  # used to render, does send the header this test forbids.
  def test_the_harness_sees_the_header_a_default_module_tag_sends
    view, response = view_with_response
    view.javascript_include_tag("studio/alpine", type: "module")

    assert_includes response.headers["link"].to_s, "modulepreload"
  end

  def test_the_module_tags_keep_their_place_and_attributes
    html, = render_head
    scripts = Nokogiri::HTML(html).css("script")
    importmap = scripts.index { |script| script["type"] == "importmap" }
    refute_nil importmap

    %w[studio/alpine studio/sticky_table_header].each do |source|
      index = scripts.index { |script| script["src"].to_s.include?(source) }
      refute_nil index, "the head does not load #{source}"
      assert_operator importmap, :<, index, "#{source} is above the import map"
      script = scripts[index]
      assert_equal "module", script["type"]
      assert_equal "reload", script["data-turbo-track"]
      assert_nil script["preload_links_header"], "the option leaked into the tag"
      assert_nil script["preload-links-header"], "the option leaked into the tag"
    end
  end

  # A view the head does not render can send the header too, on any page that shows it.
  def test_every_engine_module_include_tag_opts_out_of_the_header
    tags = self.class.module_include_tags
    refute_empty tags, "found no module include tag, so this rule checks nothing"
    tags.each do |view, tag|
      assert_match(/preload_links_header:\s*false/, tag, "#{view}: #{tag}")
    end
  end

  def self.module_include_tags
    Dir[File.join(ROOT, "app/views/**/*.erb")].flat_map do |view|
      File.read(view).scan(INCLUDE_TAG)
          .grep(/type:\s*["':]?module/)
          .map { |tag| [view.delete_prefix("#{ROOT}/"), tag] }
    end
  end

  private

  def view_with_response
    view = ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ROOT, "app/views")])
    response = ActionDispatch::Response.new
    # The helper asks respond_to?(:response), which a view answers from its controller.
    view.controller = FakeController.new(response, nil)
    def view.csrf_meta_tags = ""
    def view.csp_meta_tag = ""
    def view.studio_theme_css_tag = ""
    def view.javascript_importmap_tags = %(<script type="importmap"></script>).html_safe
    def view.javascript_import_module_tag(*) = ""
    [view, response]
  end

  def render_head
    view, response = view_with_response
    html = view.render(partial: "layouts/studio/head")
    [html, response.headers["link"].to_s]
  end
end
