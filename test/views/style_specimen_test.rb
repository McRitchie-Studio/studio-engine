# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [component] The style guide's specimen card (app/views/style/_specimen.html.erb)
# names its trick. Alex McRitchie, 2026-11-06: "the HTML isn't real helpful since
# agents can get that information from other places. I really just need to have a good
# naming convention so I can convey an idea to my agents." So a card shows the trick's
# name as its heading, a one-line note and the class or helper small and muted, all
# read from config/studio_tricks.yml, and its one Copy copies the agent line. No markup
# snippet. And the whole page: every card has a name, and every name has a card.
class StyleSpecimenTest < ActiveSupport::TestCase
  GEM_VIEWS = File.join(Gem::Specification.find_by_name("solana-studio").gem_dir, "app/views").freeze

  def view
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views", GEM_VIEWS])
    view.extend(Studio::Engine.helpers)
    view
  end

  def card(**locals)
    @html = view.render(layout: "style/specimen", locals: locals) { "<button class=\"btn sheen\">Go</button>".html_safe }
    Nokogiri::HTML.fragment(@html).at_css("article")
  end

  test "a card shows the trick's name, note and token, and copies the agent line" do
    article = card(trick: "sheen")

    assert_equal "sheen", article["data-trick"]
    assert_equal "Sheen", article.at_css("h4[data-trick-name]").text
    assert_includes article.at_css("h4")["class"].split, "type-h4", "the name is the heading"
    assert_equal "Adds a band of light that sweeps across the button.", article.at_css("[data-trick-note]").text
    token = article.at_css("code[data-trick-token]")
    assert_equal ".sheen", token.text
    assert_includes token["class"].split, "text-muted", "the token is small and muted"
    assert_includes token["class"].split, "text-2xs"
    assert article.at_css("button.btn.sheen"), "the caller's block is the stage"

    copies = article.css("button[aria-label^='Copy']")
    assert_equal 1, copies.size, "one Copy"
    assert_equal "Sheen — .sheen; Sheen · loop — .sheen--loop", copies.first["data-trick-copy"]
    # The raw markup: an HTML4 parser mangles Alpine's @click.
    assert_includes @html, %(@click="navigator.clipboard?.writeText($el.dataset.trickCopy);), "Copy writes the agent line"
  end

  test "the usage snippet is gone" do
    article = card(trick: "fizz")
    assert_nil article.at_css("pre"), "no snippet box"
    assert_nil article.at_css("[x-ref=snippet], [x-ref=klass]")
    refute_includes article.to_html, "Copy usage snippet"
  end

  test "a variant card is named for its variant and copies only its own line" do
    article = card(trick: "loader", variant: "orbit")

    assert_equal "orbit", article["data-trick-variant"]
    assert_equal "Loader · orbit", article.at_css("[data-trick-name]").text
    assert_equal "config.loader = :orbit", article.at_css("[data-trick-token]").text
    assert_equal "Loader · orbit — config.loader = :orbit", article.at_css("[data-trick-copy]")["data-trick-copy"]
  end

  test "disabled stays present and flagged; openable keeps its click" do
    off = card(trick: "level_badge", disabled: true)
    assert_equal "true", off["aria-disabled"]
    assert_includes off.text, "disabled on this app"
    assert_includes off.at_css("div.grayscale")["class"], "pointer-events-none"
    assert_equal "Level Badge", off.at_css("[data-trick-name]").text, "a disabled card keeps its name"

    open = card(trick: "level_badge", disabled: true, openable: true, disabled_label: "off here")
    assert_includes open.text, "off here"
    refute_includes open.at_css("div.grayscale")["class"], "pointer-events-none"

    assert_nil card(trick: "sheen")["aria-disabled"], "an enabled card is not marked"
  end

  test "an unknown trick fails the render, never a headless card" do
    error = assert_raises(ActionView::Template::Error) { card(trick: "no_such_trick") }
    assert_match(/no trick "no_such_trick"/, error.message)
  end

  # The whole page, every section that renders a card: each card is named, the names
  # on the page are unique, and every name in the registry is on the page, so the
  # glossary never names a trick nobody can see.
  test "every card on /admin/style has a name, and every registered trick has a card" do
    doc = Nokogiri::HTML.fragment(view.render(template: "style/index"))
    cards = doc.css("article[data-trick]")
    assert_operator cards.size, :>=, 40

    named = cards.map { |c| c.at_css("[data-trick-name]")&.text }
    refute_includes named, nil, "a headless card"
    assert_equal named.uniq, named, "a name on two cards: #{named.tally.select { |_, n| n > 1 }.keys.inspect}"

    on_page = doc.css("[data-trick]").map { |c| c["data-trick"] }.uniq
    assert_equal Studio::Tricks.all.map(&:key).sort, on_page.sort, "registered tricks without a card, or the reverse"

    %w[tricks loaders tasks].each do |section|
      assert_nil doc.at_css("section##{section} pre"), "#{section}: no markup snippet"
    end
  end
end
