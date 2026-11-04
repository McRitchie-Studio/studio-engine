# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [integration] /admin/schema lists each table's indexes. Rails returns an expression
# index's columns as one String, not an Array, and the page called join on it: a 500
# for any database holding one (found on the hub, which has four).
class SchemaPageExpressionIndexTest < ActiveSupport::TestCase
  Index = Struct.new(:columns, :unique, keyword_init: true)
  Column = Struct.new(:name, :sql_type, :type, :null, :default, keyword_init: true)

  def render_with(indexes)
    ActionController::Base.render(template: "schema/index", layout: false, assigns: {
      tables: [ { name: "people", columns: [ Column.new(name: "id", sql_type: "bigint", type: :integer, null: false) ], indexes: indexes } ]
    })
  end

  test "[integration] an expression index renders its expression, beside a plain one" do
    html = render_with([
      Index.new(columns: "lower((email)::text)", unique: true),
      Index.new(columns: %w[first_name last_name], unique: false)
    ])

    assert_includes CGI.unescapeHTML(html), "lower((email)::text)"
    assert_includes html, "first_name, last_name"
  end
end
