# frozen_string_literal: true

module Studio
  # Every state Studio::TableComponent can show: rows, a sorted column in each
  # direction, and the empty row. No @param tags: the gallery takes no input.
  class TableComponentPreview < ViewComponent::Preview
    ROWS = [
      { name: "Ada Lovelace", role: "Admin", tasks: 12, status: "passed" },
      { name: "Grace Hopper", role: "Builder", tasks: 7, status: "blocked" },
      { name: "Katherine Johnson", role: "Reviewer", tasks: 3, status: "waiting" }
    ].freeze

    # Rows, a badge cell, and no sort.
    def rows
      render_with_template(locals: { rows: ROWS, sort: nil, direction: nil })
    end

    # Sorted by name, ascending: aria-sort and the up arrow.
    def sorted_ascending
      render_with_template(template: "studio/table_component_preview/rows", locals: { rows: ROWS, sort: "name", direction: "asc" })
    end

    # Sorted by tasks, descending.
    def sorted_descending
      render_with_template(template: "studio/table_component_preview/rows", locals: { rows: ROWS.sort_by { |r| -r[:tasks] }, sort: "tasks", direction: "desc" })
    end

    # No rows: the empty row, an EmptyStateComponent across every column.
    def empty
      render_with_template(template: "studio/table_component_preview/rows", locals: { rows: [], sort: nil, direction: nil })
    end
  end
end
