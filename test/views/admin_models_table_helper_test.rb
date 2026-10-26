# frozen_string_literal: true

require "test_helper"
require "uri"
require "action_view"
require_relative "../../app/helpers/studio/admin_models_table_helper"

class AdminModelsTableHelperTest < Minitest::Test
  Record = Struct.new(:name)

  def view
    @view ||= begin
      v = ActionView::Base.with_empty_template_cache.with_view_paths([])
      v.extend(Studio::AdminModelsTableHelper)
      v
    end
  end

  def test_renders_shell_headers_and_rows
    html = view.admin_model_table(
      [Record.new("Alice"), Record.new("Bob")],
      key: "people", min_width: 700,
      headers: ["Name", "Role"], empty: "No people found."
    ) { |r| view.content_tag(:td, r.name) }

    assert_includes html, 'class="overflow-x-auto"'
    assert_includes html, 'id="models-people-table"'
    # An inline style, not min-w-[700px]: a width built at render time is not in
    # any source Tailwind scans, so that class compiled nowhere.
    assert_includes html, 'style="min-width: 700px"'
    refute_includes html, "min-w-["
    assert_includes html, ">Name</th>"
    assert_includes html, ">Role</th>"
    assert_includes html, ">Alice</td>"
    assert_includes html, ">Bob</td>"
    assert_includes html, "hover:bg-surface-alt/60"
  end

  def test_renders_empty_state_with_colspan
    html = view.admin_model_table(
      [], key: "people", headers: ["Name", "Role"], empty: "No people found."
    ) { |r| view.content_tag(:td, r.name) }

    assert_includes html, "No people found."
    assert_includes html, 'colspan="2"'
  end
end
