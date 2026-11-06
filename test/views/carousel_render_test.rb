# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# [unit] studio/_carousel: what the carousel renders. Its motion is a browser's
# (e2e/carousel.spec.js); this tier pins the seams: one slide per item drawn by the
# caller's block, the APG carousel attributes, the named controls, and the locals.
class CarouselRenderTest < Minitest::Test
  VIEWS = File.expand_path("../../app/views", __dir__)

  Item = Struct.new(:name)
  ITEMS = %w[Turf Cyvasse Rolio].map { |name| Item.new(name) }.freeze

  def render_carousel(items: ITEMS, **locals)
    view = ActionView::Base.with_empty_template_cache.new(
      ActionView::LookupContext.new([VIEWS]), {}, nil
    )
    html = view.render(layout: "studio/carousel", locals: { label: "Portfolio", items: items, **locals }) do |item|
      view.tag.a(item.name, href: "/#{item.name.downcase}", class: "card")
    end
    Nokogiri::HTML.fragment(html)
  end

  def region(doc) = doc.at_css("section.carousel")

  def test_each_item_is_a_slide_drawn_by_the_block
    slides = render_carousel.css(".carousel-track > .carousel-slide")

    assert_equal 3, slides.size
    assert_equal %w[Turf Cyvasse Rolio], slides.map { |slide| slide.at_css("a.card").text }
    assert_equal %w[/turf /cyvasse /rolio], slides.map { |slide| slide.at_css("a")["href"] }
  end

  def test_the_region_is_a_labelled_carousel
    section = region(render_carousel)

    assert_equal "region", section["role"]
    assert_equal "carousel", section["aria-roledescription"]
    assert_equal "Portfolio", section["aria-label"]
  end

  def test_each_slide_is_a_labelled_group
    slides = render_carousel.css(".carousel-slide")

    assert_equal %w[group] * 3, slides.map { |slide| slide["role"] }
    assert_equal %w[slide] * 3, slides.map { |slide| slide["aria-roledescription"] }
    assert_equal ["1 of 3", "2 of 3", "3 of 3"], slides.map { |slide| slide["aria-label"] }
  end

  def test_a_slide_label_names_each_slide_from_its_item
    slides = render_carousel(slide_label: ->(item) { item.name }).css(".carousel-slide")

    assert_equal %w[Turf Cyvasse Rolio], slides.map { |slide| slide["aria-label"] }
  end

  def test_the_arrows_are_named_buttons_that_control_the_track
    doc = render_carousel
    track = doc.at_css(".carousel-track")
    prev, nxt = doc.css(".carousel-button").to_a

    assert_equal "carousel-portfolio", track["id"]
    assert_equal "0", track["tabindex"], "a row of plain slides still takes the keys"
    assert_equal ["button", "button"], [prev["type"], nxt["type"]]
    assert_equal "Previous slides", prev["aria-label"]
    assert_equal "Next slides", nxt["aria-label"]
    assert_equal [track["id"]] * 2, [prev["aria-controls"], nxt["aria-controls"]]
    assert_equal "click->carousel#prev", prev["data-studio-action"]
    assert_equal "click->carousel#next", nxt["data-studio-action"]
  end

  # aria-disabled, never disabled: a disabled button drops the focus on it.
  def test_the_first_paint_rests_at_the_start
    doc = render_carousel
    prev, nxt = doc.css(".carousel-button").to_a

    assert_equal "true", prev["aria-disabled"]
    assert_nil prev["disabled"]
    assert_nil nxt["aria-disabled"]
    assert_equal ["true", nil, nil], doc.css(".carousel-dot").map { |dot| dot["aria-current"] }
  end

  def test_a_dot_per_slide_goes_to_its_slide
    dots = render_carousel.css(".carousel-dots .carousel-dot")

    assert_equal ["Go to slide 1", "Go to slide 2", "Go to slide 3"], dots.map { |dot| dot["aria-label"] }
    assert_equal %w[0 1 2], dots.map { |dot| dot["data-carousel-index"] }
    assert_equal ["click->carousel#goTo"] * 3, dots.map { |dot| dot["data-studio-action"] }
  end

  def test_the_controller_and_its_keys_sit_on_the_region
    section = region(render_carousel)

    assert_equal "carousel", section["data-studio-controller"]
    assert_equal "keydown->carousel#key", section["data-studio-action"]
    assert_equal "track", section.at_css(".carousel-track")["data-carousel-target"]
    assert_equal "polite", section.at_css("[role='status']")["aria-live"]
  end

  def test_per_view_sets_the_wide_row_and_is_held_to_one_to_six
    assert_equal "--carousel-per-view: 3", region(render_carousel)["style"]
    assert_equal "--carousel-per-view: 4", region(render_carousel(per_view: 4))["style"]
    assert_equal "--carousel-per-view: 2.5", region(render_carousel(per_view: 2.5))["style"]
    assert_equal "--carousel-per-view: 1", region(render_carousel(per_view: 0))["style"]
    assert_equal "--carousel-per-view: 6", region(render_carousel(per_view: 40))["style"]
  end

  def test_id_data_and_class_name_reach_the_region
    doc = render_carousel(id: "apps-row", data: { test: "websites-carousel" }, class_name: "max-w-5xl mx-auto")
    section = region(doc)

    assert_equal "apps-row", doc.at_css(".carousel-track")["id"]
    assert_equal ["apps-row"], doc.css(".carousel-button").map { |b| b["aria-controls"] }.uniq
    assert_equal "websites-carousel", section["data-test"]
    assert_equal %w[carousel max-w-5xl mx-auto], section["class"].split
    assert_equal "carousel", section["data-studio-controller"], "a data hook keeps the controller"
  end

  def test_no_items_renders_an_empty_track
    doc = render_carousel(items: [])

    assert_empty doc.css(".carousel-slide")
    assert_empty doc.css(".carousel-dot")
  end
end
