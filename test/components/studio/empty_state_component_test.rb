# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "view_component/test_case"

# [unit] Studio::EmptyStateComponent renders its message, detail, icon and one
# action from its declared inputs, framed in the shipped .empty-state card or
# bare. The components/empty_state partial is held to it too.
class Studio::EmptyStateComponentTest < ViewComponent::TestCase
  def render_inline(component, &block)
    @fragment = super
  end

  def root
    nodes = @fragment.css("[data-empty-state]")
    assert_equal 1, nodes.size, "expected one [data-empty-state] in #{@fragment.to_html}"
    nodes.first
  end

  test "the message alone renders the framed .empty-state with the message on the type scale" do
    render_inline(Studio::EmptyStateComponent.new(message: "Nothing here"))

    assert_equal "empty-state", root[:class]
    message = root.at_css("p")
    assert_equal "Nothing here", message.text
    assert_includes message[:class].split, "type-body"
    assert_equal 1, root.css("p").size
  end

  test "detail renders a second line in fine print" do
    render_inline(Studio::EmptyStateComponent.new(message: "Nothing here", detail: "Yet"))

    detail = root.css("p").last
    assert_equal "Yet", detail.text
    assert_includes detail[:class].split, "type-fine"
  end

  test "the block may be the message" do
    render_inline(Studio::EmptyStateComponent.new) { "From the block" }

    assert_equal "From the block", root.at_css("p").text.strip
  end

  test "the icon slot renders above the message, hidden from assistive tech" do
    render_inline(Studio::EmptyStateComponent.new(message: "x")) { |e| e.with_icon { "*" } }

    assert_equal "*", root.at_css("[aria-hidden='true']").text
  end

  test "the action is a Studio::ButtonComponent" do
    render_inline(Studio::EmptyStateComponent.new(message: "x")) { |e| e.with_action(label: "Add one", href: "/new") }

    link = root.at_css("a.btn.btn-primary")
    refute_nil link
    assert_equal "/new", link[:href]
    assert_equal "Add one", link.text.strip
  end

  test "no action renders no button" do
    render_inline(Studio::EmptyStateComponent.new(message: "x"))

    assert_empty root.css(".btn")
  end

  test "framed: false drops the card" do
    render_inline(Studio::EmptyStateComponent.new(message: "x", framed: false))

    refute_includes root[:class].split, "empty-state"
    assert_includes root[:class].split, "text-center"
  end

  test "the message and detail are escaped" do
    render_inline(Studio::EmptyStateComponent.new(message: "<b>m</b>", detail: "<i>d</i>"))

    assert_empty root.css("b, i")
  end

  test "no message is refused" do
    assert_raises(ArgumentError) { render_inline(Studio::EmptyStateComponent.new) }
  end

  test "the components/empty_state partial renders the component" do
    html = ActionController::Base.render(partial: "components/empty_state", locals: { message: "Nothing", detail: "Yet" })
    fragment = Nokogiri::HTML.fragment(html)

    root = fragment.at_css("div.empty-state[data-empty-state]")
    refute_nil root
    assert_equal %w[Nothing Yet], root.css("p").map(&:text)
  end
end
