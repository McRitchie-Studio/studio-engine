# frozen_string_literal: true

require "test_helper"
require "uri"
require "action_view"

class StickyTableHeaderAssetsTest < Minitest::Test
  def setup
    Studio.sticky_table_headers = false
  end

  def test_head_omits_sticky_table_assets_by_default
    html = render_head

    refute_includes html, "studio/sticky_table_header"
  end

  def test_head_includes_sticky_table_assets_when_enabled
    Studio.sticky_table_headers = true

    html = render_head

    assert_includes html, "studio/sticky_table_header"
    assert_includes html, "stylesheet"
    assert_includes html, "script"
  end

  private

  def render_head
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    def view.csrf_meta_tags = ""
    def view.csp_meta_tag = ""
    def view.studio_theme_css_tag = ""
    def view.javascript_importmap_tags = "<script></script>"
    def view.javascript_import_module_tag(*) = ""

    view.render(partial: "layouts/studio/head")
  end
end
