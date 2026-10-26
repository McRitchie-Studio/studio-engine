# frozen_string_literal: true

module Studio
  # Shared shell for /admin/models tables. Renders the overflow wrapper + thead +
  # tbody + empty state so each consumer `_<key>_table` partial only declares its
  # columns. Exposed to consumer admin/models views via the AdminModels concern.
  #
  #   <%= admin_model_table(records, key: "users", min_width: 760,
  #         headers: ["User", "Role", "Created"], empty: "No users found.") do |user| %>
  #     <td class="px-4 py-3"><%= user.display_name %></td>
  #     <td class="px-4 py-3"><%= user.role %></td>
  #     <td class="px-4 py-3"><%= time_ago_in_words(user.created_at) %> ago</td>
  #   <% end %>
  #
  # min_width is an inline style, not a `min-w-[Npx]` class: Tailwind compiles
  # only class names it can read in source, and a width interpolated at render
  # time is never in source, so the class painted only in a host whose own
  # markup happened to spell the same width.
  #
  # The block yields each record and returns that row's <td> cells. Output matches
  # the long-standing markup (id="models-<key>-table", overflow wrapper, hover
  # rows, colspan empty state) so existing view assertions keep passing.
  module AdminModelsTableHelper
    def admin_model_table(records, key:, headers:, min_width: 940, empty: "No records found.", &row)
      header_row = content_tag(:tr, safe_join(headers.map { |label|
        content_tag(:th, label, class: "px-4 py-3 text-left font-semibold")
      }))

      body =
        if records.any?
          safe_join(records.map { |record|
            content_tag(:tr, capture(record, &row), class: "hover:bg-surface-alt/60 transition")
          })
        else
          content_tag(:tr, content_tag(:td, empty,
            colspan: headers.size, class: "px-4 py-10 text-center text-muted"))
        end

      table = content_tag(:table,
        content_tag(:thead, header_row, class: "bg-surface-alt text-muted text-xs uppercase tracking-wide") +
          content_tag(:tbody, body, class: "divide-y divide-subtle"),
        id: "models-#{key}-table", class: "w-full text-sm", style: "min-width: #{min_width.to_i}px")

      content_tag(:div, table, class: "overflow-x-auto")
    end
  end
end
