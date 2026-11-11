# frozen_string_literal: true

module Studio
  # A data table: columns, rows, a sort hook in plain links, and an empty row.
  #
  #   render Studio::TableComponent.new(
  #     id: "users-table",
  #     rows: @users,
  #     columns: [
  #       { key: :name, label: "User", sortable: true },
  #       { key: :role, label: "Role", cell: ->(user) { render Studio::BadgeComponent.new(text: user.role) } },
  #       { key: :created_at, label: "Joined", align: :right, cell: ->(user) { l(user.created_at.to_date) } }
  #     ],
  #     sort: params[:sort], direction: params[:direction],
  #     empty: "No users yet.",
  #     caption: "Team members"
  #   )
  #
  # A column is a Hash: key: (required), label: (required), sortable: (false),
  # align: (:left, :center or :right) and cell: (a callable that takes the row and
  # returns its cell; without one the cell is row[key] for a Hash, or
  # row.public_send(key)). A cell's value is escaped unless it is html_safe, so a
  # cell may render a component.
  #
  # SORTING is links, no script. A sortable header is a link to the current URL
  # with ?sort=<key>&direction=<asc|desc> (the page param dropped), the
  # team_sort_url pattern from Studio::AdminModels; the column already sorted asc
  # links to desc. The controller sorts. sort_url: takes a callable (key,
  # direction) for an app with its own URL shape. The sorted header carries
  # aria-sort and the arrow.
  #
  # PHONE LAYOUT is a horizontal scroll, as every engine table does today
  # (admin_model_table, the emails index): the table keeps its columns and its
  # wrapper scrolls. min_width: sets the width under which it scrolls.
  #
  # A NAME AND A KEYBOARD SCROLL. The scroll wrapper takes tabindex="0", so a
  # keyboard user can focus it and scroll it with the arrow keys (WCAG 2.1.1; axe's
  # scrollable-region-focusable), and it shows a focus ring inside its edge, so a
  # card's overflow-hidden cannot clip it.
  # caption: renders a <caption> (visually hidden: the page's own heading is the
  # visible title) and aria_label: labels the table without one. Either one also
  # makes the wrapper a named role="region", so a screen reader announces what it
  # entered. With neither, the wrapper stays focusable but takes no role: a
  # region with no name is noise. Pass one.
  #
  # Its public surface, which a release changes only with a Breaking line in the
  # changelog (docs/FRONT_END_STANDARD.md, "A primitive's public surface"):
  #   inputs   rows:, columns:, id:, sort:, direction:, sort_url:, sort_param:,
  #            direction_param:, empty:, min_width:, sticky_header:,
  #            caption:, aria_label:
  #   data-*   data-table on the wrapper; data-table-sort-key on a sortable
  #            header; data-table-empty on the empty row; data-sticky-table-header
  #            on the table when sticky_header: (studio/sticky_table_header)
  #   aria-*   aria-sort on the sorted header; aria-label on the table
  #            (aria_label:) and on the wrapper, role="region" (caption: or
  #            aria_label:)
  #   tabindex tabindex="0" on the wrapper
  #
  # Every class string is written out whole: Tailwind finds utilities by scanning
  # source text, and engine.css adds app/components to every host's scan.
  class TableComponent < ViewComponent::Base
    strip_trailing_whitespace

    WRAPPER = "overflow-x-auto focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-primary"
    CAPTION = "sr-only"
    TABLE = "w-full type-body"
    HEAD = "bg-surface-alt text-muted type-fine uppercase tracking-wide"
    BODY = "divide-y divide-subtle"
    ROW = "hover:bg-surface-alt/60 transition"
    HEADER_CELL = "px-4 py-3 font-semibold"
    CELL = "px-4 py-3 text-body"
    SORT_LINK = "inline-flex items-center gap-1 rounded-sm hover:text-heading focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
    SORT_ARROW = "text-primary-ink"

    ALIGN = {
      left: "text-left",
      center: "text-center",
      right: "text-right"
    }.freeze

    DIRECTIONS = %w[asc desc].freeze
    ARIA_SORT = { "asc" => "ascending", "desc" => "descending" }.freeze
    ARROWS = { "asc" => "↑", "desc" => "↓" }.freeze

    Column = Struct.new(:key, :label, :sortable, :align, :cell, keyword_init: true)

    attr_reader :rows, :columns, :empty

    def initialize(rows:, columns:, id: nil, sort: nil, direction: nil, sort_url: nil, sort_param: "sort",
                   direction_param: "direction", empty: "Nothing here yet.", min_width: nil, sticky_header: false,
                   caption: nil, aria_label: nil)
      super()
      raise ArgumentError, "Studio::TableComponent needs at least one column" if columns.blank?

      @rows = rows.to_a
      @columns = columns.map { |column| build_column(column) }
      @id = id
      @sort = sort.presence&.to_s
      @direction = DIRECTIONS.include?(direction.to_s) ? direction.to_s : "asc"
      @sort_url = sort_url
      @sort_param = sort_param.to_s
      @direction_param = direction_param.to_s
      @empty = empty
      @min_width = min_width
      @sticky_header = sticky_header ? true : false
      @caption = caption.presence
      @aria_label = aria_label.presence
    end

    attr_reader :caption

    # The name the wrapper's region announces: the caption, else aria_label:.
    def accessible_name = @caption || @aria_label

    def wrapper_attributes
      attrs = { class: WRAPPER, tabindex: "0", data: { table: "" } }
      if accessible_name
        attrs[:role] = "region"
        attrs[:aria] = { label: accessible_name }
      end
      attrs
    end

    def table_attributes
      attrs = { class: TABLE, id: @id }
      attrs[:style] = "min-width: #{@min_width.to_i}px" if @min_width
      attrs[:data] = { sticky_table_header: "" } if @sticky_header
      attrs[:aria] = { label: @aria_label } if @aria_label && !@caption
      attrs.compact
    end

    def header_attributes(column)
      attrs = { scope: "col", class: [HEADER_CELL, ALIGN.fetch(column.align)].join(" ") }
      if column.sortable
        attrs[:data] = { table_sort_key: column.key }
        attrs[:aria] = { sort: ARIA_SORT.fetch(@direction) } if sorted?(column)
      end
      attrs
    end

    def cell_classes(column)
      [CELL, ALIGN.fetch(column.align)].join(" ")
    end

    def sorted?(column) = @sort == column.key

    def arrow = ARROWS.fetch(@direction)

    # The next direction for a header link: the sorted column flips, any other
    # starts ascending.
    def next_direction(column)
      sorted?(column) && @direction == "asc" ? "desc" : "asc"
    end

    def sort_href(column)
      direction = next_direction(column)
      return @sort_url.call(column.key, direction) if @sort_url

      query = request.query_parameters.merge(@sort_param => column.key, @direction_param => direction)
      query.delete("page")
      "#{request.path}?#{query.to_query}"
    end

    def cell_value(column, row)
      return column.cell.call(row) if column.cell
      return row[column.key.to_sym] || row[column.key] if row.is_a?(Hash)

      row.public_send(column.key)
    end

    private

    def build_column(column)
      column = column.to_h.symbolize_keys
      unknown = column.keys - Column.members
      raise ArgumentError, "unknown column key #{unknown.first.inspect}; expected #{Column.members.join(', ')}" if unknown.any?
      raise ArgumentError, "Studio::TableComponent: every column takes key: and label:" if column[:key].blank? || column[:label].blank?

      align = (column[:align] || :left).to_sym
      raise ArgumentError, "unknown align #{align.inspect}; expected one of #{ALIGN.keys.join(', ')}" unless ALIGN.key?(align)

      Column.new(key: column[:key].to_s, label: column[:label], sortable: column[:sortable] ? true : false,
                 align: align, cell: column[:cell])
    end
  end
end
