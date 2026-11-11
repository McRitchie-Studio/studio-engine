# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "view_component/test_case"

# [unit] Studio::ButtonComponent renders every tone, size and state from its
# declared inputs, on the engine's shipped btn-* classes and its aria-busy
# loading contract, and refuses the inputs it does not take.
class Studio::ButtonComponentTest < ViewComponent::TestCase
  def render_inline(component, &block)
    @fragment = super
  end

  def element(tag = "button")
    nodes = @fragment.css("#{tag}.btn")
    assert_equal 1, nodes.size, "expected one #{tag}.btn in #{@fragment.to_html}"
    nodes.first
  end

  def classes(tag = "button") = element(tag)[:class].split

  # Written out here, not read from the component, so a change to the mapping
  # shows up as a diff someone has to agree to.
  TONE_CLASSES = { primary: "btn-primary", secondary: "btn-secondary", quiet: "btn-neutral", danger: "btn-danger",
                   outline: "btn-outline" }.freeze
  SIZE_CLASSES = { sm: "btn-sm", md: "btn-md", lg: "btn-lg" }.freeze

  test "each tone renders .btn and the tone's shipped btn-* class" do
    TONE_CLASSES.each do |tone, css|
      render_inline(Studio::ButtonComponent.new(label: "Go", tone: tone))

      assert_includes classes, "btn", tone.inspect
      assert_includes classes, css, tone.inspect
      (TONE_CLASSES.values - [css]).each { |other| refute_includes classes, other, tone.inspect }
      assert_equal "Go", element.text.strip
    end
  end

  test "each size renders btn-sm, btn-md or btn-lg" do
    SIZE_CLASSES.each do |size, css|
      render_inline(Studio::ButtonComponent.new(label: "Go", size: size))

      SIZE_CLASSES.values.compact.each do |name|
        name == css ? assert_includes(classes, name, size.inspect) : refute_includes(classes, name, size.inspect)
      end
    end
  end

  test "every tone and size together" do
    TONE_CLASSES.each_key do |tone|
      SIZE_CLASSES.each_key do |size|
        render_inline(Studio::ButtonComponent.new(label: "x", tone: tone, size: size))
        assert_includes classes, TONE_CLASSES[tone]
      end
    end
  end

  test "the default is a primary md button of type button" do
    render_inline(Studio::ButtonComponent.new(label: "Go"))

    assert_equal "button", element[:type]
    assert_includes classes, "btn-primary"
    assert_includes classes, "btn-md"
    refute element.key?("disabled")
    refute element.key?("aria-busy")
  end

  test "tone and size may be strings" do
    render_inline(Studio::ButtonComponent.new(label: "x", tone: "danger", size: "sm"))

    assert_includes classes, "btn-danger"
    assert_includes classes, "btn-sm"
  end

  test "an href renders a link with no type" do
    render_inline(Studio::ButtonComponent.new(label: "Docs", href: "/docs", tone: :quiet))

    link = element("a")
    assert_equal "/docs", link[:href]
    assert_nil link[:type]
    assert_includes classes("a"), "btn-neutral"
    assert_empty @fragment.css("button")
  end

  test "disabled renders a disabled button" do
    render_inline(Studio::ButtonComponent.new(label: "Go", disabled: true))

    assert element.key?("disabled")
    refute element.key?("aria-busy")
  end

  test "a disabled link loses its href and says it is disabled" do
    render_inline(Studio::ButtonComponent.new(label: "Docs", href: "/docs", disabled: true))

    link = element("a")
    assert_nil link[:href]
    assert_equal "true", link["aria-disabled"]
    assert_equal "link", link[:role]
    assert_includes classes("a"), "opacity-50"
  end

  test "loading is aria-busy, disabled, and carries the pending loader" do
    render_inline(Studio::ButtonComponent.new(label: "Save", loading: true))

    assert_equal "true", element["aria-busy"]
    assert element.key?("disabled")
    assert_equal 1, element.css(".studio-loader[data-loader-pending]").size
    assert_equal "Save", element.text.strip
  end

  test "busy_label puts the label in data-loader-idle and the words in data-loader-busy" do
    render_inline(Studio::ButtonComponent.new(label: "Save", type: "submit", loading: true, busy_label: "Saving…"))

    assert_equal "Save", element.at_css("[data-loader-idle]").text
    assert_equal "Saving…", element.at_css("[data-loader-busy]").text
  end

  test "a submit button carries the hidden pending loader so a busy form shows it" do
    render_inline(Studio::ButtonComponent.new(label: "Save", type: "submit"))

    assert_equal "submit", element[:type]
    refute element.key?("aria-busy")
    assert_equal 1, element.css(".studio-loader[data-loader-pending]").size
  end

  test "a plain button carries no loader" do
    render_inline(Studio::ButtonComponent.new(label: "Go"))

    assert_empty element.css(".studio-loader")
  end

  test "the icon slot renders before the label, hidden from assistive tech, idle only" do
    render_inline(Studio::ButtonComponent.new(label: "New")) { |b| b.with_icon { "+" } }

    icon = element.at_css("span[aria-hidden='true'][data-loader-idle]")
    refute_nil icon
    assert_equal "+", icon.text
  end

  test "the block may be the label" do
    render_inline(Studio::ButtonComponent.new) { "From the block" }

    assert_equal "From the block", element.text.strip
  end

  test "id, title, data and aria pass through" do
    render_inline(Studio::ButtonComponent.new(label: "x", id: "go", title: "Go now", data: { action: "click->x#y" }, aria: { label: "Go" }))

    assert_equal "go", element[:id]
    assert_equal "Go now", element[:title]
    assert_equal "click->x#y", element["data-action"]
    assert_equal "Go", element["aria-label"]
  end

  test "the label is escaped" do
    render_inline(Studio::ButtonComponent.new(label: "<b>x</b>"))

    assert_equal "<b>x</b>", element.text.strip
    assert_empty element.css("b")
  end

  test "an unknown tone, size or type is refused, naming the choices" do
    assert_match(/primary, secondary, quiet, danger, outline/, assert_raises(ArgumentError) { Studio::ButtonComponent.new(label: "x", tone: :mint) }.message)
    assert_match(/sm, md, lg/, assert_raises(ArgumentError) { Studio::ButtonComponent.new(label: "x", size: :xl) }.message)
    assert_match(/button, submit, reset/, assert_raises(ArgumentError) { Studio::ButtonComponent.new(label: "x", type: "link") }.message)
  end

  test "loading with an href is refused" do
    assert_raises(ArgumentError) { Studio::ButtonComponent.new(label: "x", href: "/", loading: true) }
  end

  test "no label and no block is refused" do
    assert_raises(ArgumentError) { render_inline(Studio::ButtonComponent.new) }
  end

  # md's label is on the type scale (body, 1x --type-base), not the bare .btn's
  # text-sm: the component adds btn-md, and btn-md is compiled from that multiple.
  test "the md size sets its label on the type scale through btn-md" do
    render_inline(Studio::ButtonComponent.new(label: "Go"))
    refute_includes classes, "text-sm"

    css = File.read(File.expand_path("../../../app/assets/tailwind/studio_engine/engine.css", __dir__))
    rule = css[/@utility btn-md \{[^}]*\}/]
    refute_nil rule, "engine.css defines no btn-md utility"
    assert_includes rule, "font-size: calc(var(--type-base, 16px) * 1)"
  end

  test "the outline tone draws btn-outline as a button, a link and a loading button" do
    render_inline(Studio::ButtonComponent.new(label: "Export", tone: :outline))
    assert_includes classes, "btn-outline"

    render_inline(Studio::ButtonComponent.new(label: "Export", tone: :outline, href: "/export"))
    assert_includes classes("a"), "btn-outline"

    render_inline(Studio::ButtonComponent.new(label: "Export", tone: :outline, loading: true))
    assert_equal "true", element["aria-busy"]
    assert_includes classes, "btn-outline"
  end
end
