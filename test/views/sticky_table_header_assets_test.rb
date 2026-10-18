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

  # The local answers for one render, either way; nil defers to the config.
  def test_head_local_turns_the_assets_on_for_one_render
    assert_includes render_head(sticky_table_headers: true), "studio/sticky_table_header"
    refute Studio.sticky_table_headers, "the local never writes the config"
    refute_includes render_head(sticky_table_headers: nil), "studio/sticky_table_header"
  end

  def test_head_local_false_turns_the_assets_off_over_the_config
    Studio.sticky_table_headers = true

    refute_includes render_head(sticky_table_headers: false), "studio/sticky_table_header"
    assert_includes render_head(sticky_table_headers: nil), "studio/sticky_table_header"
  end

  private

  def render_head(**locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    def view.csrf_meta_tags = ""
    def view.csp_meta_tag = ""
    def view.studio_theme_css_tag = ""
    def view.javascript_importmap_tags = "<script></script>"
    def view.javascript_import_module_tag(*) = ""

    view.render(partial: "layouts/studio/head", locals: locals)
  end
end
