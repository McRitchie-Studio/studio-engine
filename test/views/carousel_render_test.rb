# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require "digest"

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

  def test_the_focusable_track_has_an_accessible_name
    track = render_carousel.at_css(".carousel-track")

    assert_equal "0", track["tabindex"]
    assert_equal "group", track["role"], "a bare div may not carry a name"
    assert_equal "Portfolio slides", track["aria-label"]
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
    assert_equal "true", section.at_css("[role='status']")["aria-atomic"], "the whole line is read, not the changed words"
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

  # --- style: :spotlight -------------------------------------------------------
  # The same region, controls and keys; the spotlight adds a class, a body around
  # each slide's block (what scales), and a caption under it.

  def test_the_standard_style_adds_no_spotlight_markup
    doc = render_carousel

    assert_equal %w[carousel], region(doc)["class"].split
    assert_empty doc.css(".carousel-spotlight-body, .carousel-caption")
    assert_equal render_carousel.to_html, render_carousel(style: :standard).to_html
  end

  def test_spotlight_marks_the_region_and_wraps_each_slide_in_a_body
    doc = render_carousel(style: :spotlight)
    section = region(doc)

    assert_equal %w[carousel carousel-spotlight], section["class"].split
    bodies = doc.css(".carousel-slide > .carousel-spotlight-body")
    assert_equal 3, bodies.size
    assert_equal %w[Turf Cyvasse Rolio], bodies.map { |body| body.at_css("a.card").text }
    assert_equal "carousel", section["data-studio-controller"], "the same controller"
    assert_equal "region", section["role"]
    assert_equal ["Previous slide", "Next slide"], doc.css(".carousel-button").map { |b| b["aria-label"] },
                 "a spotlight arrow moves one slide, so its name is singular"
    assert_equal 3, doc.css(".carousel-dot").size
    assert_includes region(render_carousel(style: "spotlight"))["class"].split, "carousel-spotlight",
                    "a string style works as the symbol does"
  end

  def test_a_caption_writes_a_line_under_each_slide_from_its_item
    doc = render_carousel(style: :spotlight, caption: ->(item) { "#{item.name}, live" })
    captions = doc.css(".carousel-slide > .carousel-caption")

    assert_equal ["Turf, live", "Cyvasse, live", "Rolio, live"], captions.map(&:text)
    assert_equal %w[carousel-spotlight-body carousel-caption],
                 doc.at_css(".carousel-slide").element_children.map { |el| el["class"] },
                 "the caption sits under the body, outside what scales"
    assert_empty render_carousel(style: :spotlight).css(".carousel-caption"), "no caption without the callable"
  end

  def test_a_caption_is_escaped
    doc = render_carousel(style: :spotlight, caption: ->(_) { "<b>bold</b>" })

    assert_empty doc.css(".carousel-caption b")
    assert_equal "<b>bold</b>", doc.at_css(".carousel-caption").text
  end

  def test_an_unknown_style_is_refused
    error = assert_raises(StandardError) { render_carousel(style: :fancy) }
    # This bare test view wraps the error twice; the ArgumentError is in the chain.
    chain = []
    while error
      chain << error
      error = error.cause
    end
    refused = chain.find { |e| e.is_a?(ArgumentError) }
    assert refused, "an ArgumentError in #{chain.map(&:class).inspect}"
    assert_match(/not :standard, :spotlight or :cascade/, refused.message)
  end

  # THE START: the slide the row opens on (start:).
  FOUR = (ITEMS + [Item.new("Moms")]).freeze

  def current_dot(doc) = doc.at_css(".carousel-dot[aria-current='true']")["data-carousel-index"]
  def arrows(doc) = doc.css(".carousel-button").map { |b| b["aria-disabled"] }

  def test_a_spotlight_opens_on_its_middle_slide_by_default
    doc = render_carousel(style: :spotlight)

    assert_equal "1", region(doc)["data-carousel-start"]
    assert_equal ["2 of 3"], doc.css(".carousel-slide[data-carousel-start-slide]").map { |s| s["aria-label"] }
    assert_equal ["2 of 3"], doc.css(".carousel-slide[data-current]").map { |s| s["aria-label"] }
    assert_equal "1", current_dot(doc)
    assert_equal ["false", nil], arrows(doc), "neither arrow is at an end"
  end

  def test_the_middle_of_an_even_set_is_the_later_of_the_two
    doc = render_carousel(items: FOUR, style: :spotlight)

    assert_equal "2", region(doc)["data-carousel-start"]
    assert_equal "2", current_dot(doc)
  end

  # A looping spotlight's wrap shows the last slide left of the first, so it opens on
  # the host's first item; an explicit start: still wins, and a row of one slide,
  # which does not wrap, keeps the middle (its only slide).
  def test_a_looping_spotlight_opens_on_its_first_slide_by_default
    doc = render_carousel(items: FOUR, style: :spotlight, loop: true)

    assert_nil region(doc)["data-carousel-start"]
    assert_empty doc.css("[data-carousel-start-slide]")
    assert_equal ["1 of 4"], doc.css(".carousel-slide[data-current]").map { |s| s["aria-label"] }
    assert_equal "0", current_dot(doc)
    assert_equal ["false", nil], arrows(doc), "a looping row disables neither arrow"
  end

  def test_a_looping_spotlight_still_takes_an_explicit_start
    assert_equal "2", region(render_carousel(items: FOUR, style: :spotlight, loop: true, start: :middle))["data-carousel-start"]
    assert_equal "3", region(render_carousel(items: FOUR, style: :spotlight, loop: true, start: 3))["data-carousel-start"]
    assert_equal "2", region(render_carousel(items: FOUR, style: :spotlight, loop: false))["data-carousel-start"], "no loop, the middle"
  end

  def test_a_standard_row_opens_on_its_first_slide_by_default
    doc = render_carousel

    assert_nil region(doc)["data-carousel-start"]
    assert_empty doc.css("[data-carousel-start-slide], .carousel-slide[data-current]")
    assert_equal "0", current_dot(doc)
    assert_equal ["true", nil], arrows(doc)
  end

  def test_start_takes_an_index
    doc = render_carousel(items: FOUR, start: 1)

    assert_equal "1", region(doc)["data-carousel-start"]
    assert_equal ["2 of 4"], doc.css(".carousel-slide[data-carousel-start-slide]").map { |s| s["aria-label"] }
    assert_equal "1", current_dot(doc)
  end

  def test_a_standard_row_takes_middle_too
    assert_equal "2", region(render_carousel(items: FOUR, start: :middle))["data-carousel-start"]
    assert_equal "2", region(render_carousel(items: FOUR, start: "middle"))["data-carousel-start"]
  end

  def test_start_on_the_last_slide_turns_next_off
    doc = render_carousel(style: :spotlight, start: 2)

    assert_equal ["false", "true"], arrows(doc)
  end

  def test_start_is_held_to_the_row
    assert_equal "2", region(render_carousel(start: 99))["data-carousel-start"]
    assert_nil region(render_carousel(start: -3))["data-carousel-start"]
    assert_nil region(render_carousel(items: [], style: :spotlight))["data-carousel-start"]
  end

  def test_start_zero_on_a_spotlight_adds_no_start_mark
    doc = render_carousel(style: :spotlight, start: 0)

    assert_nil region(doc)["data-carousel-start"]
    assert_empty doc.css("[data-carousel-start-slide]")
    assert_equal "0", current_dot(doc)
    assert_equal ["true", nil], arrows(doc)
  end

  def test_an_unknown_start_is_refused
    error = assert_raises(StandardError) { render_carousel(start: :end) }
    chain = []
    while error
      chain << error
      error = error.cause
    end
    refused = chain.find { |e| e.is_a?(ArgumentError) }
    assert refused, "an ArgumentError in #{chain.map(&:class).inspect}"
    assert_match(/not an index or :middle/, refused.message)
  end

  def test_a_standard_arrow_keeps_its_plural_name
    assert_equal ["Previous slides", "Next slides"], render_carousel.css(".carousel-button").map { |b| b["aria-label"] }
  end

  def test_a_standard_caption_writes_a_line_under_each_slide
    doc = render_carousel(caption: ->(item) { "#{item.name} app" })

    assert_equal ["Turf app", "Cyvasse app", "Rolio app"], doc.css(".carousel-slide > .carousel-caption").map(&:text)
    assert_equal "carousel-caption", doc.at_css(".carousel-slide").element_children.last["class"]
  end

  # LOOP AND AUTOPLAY (loop:, autoplay:).
  def ends(doc) = %w[prev next].map { |t| doc.at_css("[data-carousel-target='#{t}']")["aria-disabled"] }
  def toggle(doc) = doc.at_css("[data-carousel-target='toggle']")

  def refusal(&block)
    error = assert_raises(StandardError, &block)
    chain = []
    while error
      chain << error
      error = error.cause
    end
    chain.find { |e| e.is_a?(ArgumentError) }
  end

  def test_by_default_a_row_neither_loops_nor_plays
    doc = render_carousel

    assert_nil region(doc)["data-carousel-loop"]
    assert_nil region(doc)["data-carousel-autoplay"]
    assert_nil toggle(doc), "no pause button without autoplay"
    assert_equal 2, doc.css(".carousel-button").size
  end

  def test_a_looping_row_disables_neither_arrow_at_either_end
    assert_equal "", region(render_carousel(loop: true))["data-carousel-loop"]
    assert_equal ["false", nil], ends(render_carousel(loop: true)), "first slide"
    assert_equal ["false", nil], ends(render_carousel(loop: true, start: 2)), "last slide"
    assert_equal ["false", nil], ends(render_carousel(loop: true, style: :spotlight, start: 0))
    assert_equal ["false", nil], ends(render_carousel(loop: true, style: :spotlight, start: 2))
  end

  def test_a_looping_row_of_one_slide_has_nowhere_to_wrap
    assert_equal ["true", "true"], ends(render_carousel(items: ITEMS.first(1), loop: true))
  end

  def test_autoplay_carries_its_seconds_and_a_named_pause_button
    doc = render_carousel(autoplay: 5, loop: true, style: :spotlight)
    button = toggle(doc)

    assert_equal "5", region(doc)["data-carousel-autoplay"]
    assert_equal "button", button["type"]
    assert_equal "Pause slideshow", button["aria-label"]
    assert_equal "carousel-portfolio", button["aria-controls"]
    assert_equal "click->carousel#toggle", button["data-studio-action"]
    assert_includes button["class"].split, "carousel-button"
    assert_includes button["class"].split, "carousel-autoplay"
    assert_equal button, doc.at_css(".carousel-arrows > button"), "the pause button leads the arrows"
    assert_equal %w[true true], button.css("svg").map { |svg| svg["aria-hidden"] }
  end

  def test_autoplay_takes_a_fraction_of_a_second
    assert_equal "2.5", region(render_carousel(autoplay: 2.5))["data-carousel-autoplay"]
    assert_equal "3", region(render_carousel(autoplay: 3.0))["data-carousel-autoplay"]
  end

  def test_autoplay_nil_or_false_is_off
    [nil, false].each do |off|
      doc = render_carousel(autoplay: off)
      assert_nil region(doc)["data-carousel-autoplay"]
      assert_nil toggle(doc)
    end
  end

  def test_autoplay_refuses_what_is_not_seconds
    [0, -2, "5", true, Float::INFINITY].each do |bad|
      refused = refusal { render_carousel(autoplay: bad) }
      assert refused, "autoplay: #{bad.inspect} is refused"
      assert_match(/not a number of seconds above 0 or nil/, refused.message)
    end
  end

  # THE CASCADE (style: :cascade): a 3D stack the controller and engine.css lay out
  # from each slide's data-cascade-step. studio/carousel's cascadeStep and cascadeSlot
  # rewrite the steps on a move (test/javascript/carousel_cascade.test.mjs); this pins
  # the first paint's, which must agree with them.
  SEVEN = %w[a b c d e f g].map { |name| Item.new(name) }.freeze

  def cascade_refusal(&block)
    error = assert_raises(StandardError, &block)
    error = error.cause while error && !error.is_a?(ArgumentError)
    assert error, "an ArgumentError in the chain"
    error.message
  end

  def steps(doc) = doc.css(".carousel-slide").map { |slide| slide["data-cascade-step"] }

  def test_cascade_marks_the_region_and_wraps_each_slide_in_a_body
    doc = render_carousel(style: :cascade)
    section = region(doc)

    assert_equal %w[carousel carousel-cascade], section["class"].split
    assert_equal "5", section["data-carousel-visible"], "five in view by default"
    assert_equal "carousel", section["data-studio-controller"], "the same controller"
    assert_equal %w[Turf Cyvasse Rolio], doc.css(".carousel-slide > .carousel-cascade-body a.card").map(&:text)
    assert_empty doc.css(".carousel-spotlight-body")
    assert_equal ["Previous slide", "Next slide"], doc.css(".carousel-button").map { |b| b["aria-label"] }
    assert_equal 3, doc.css(".carousel-dot").size, "a dot per real slide"
    assert_equal %w[group] * 3, doc.css(".carousel-slide").map { |slide| slide["role"] }
    assert_empty doc.css("[data-carousel-start-slide]"), "a cascade does not scroll, so it needs no scroll target"
  end

  def test_cascade_takes_visible_three
    section = region(render_carousel(style: :cascade, visible: 3))

    assert_equal "3", section["data-carousel-visible"]
    assert_equal "5", region(render_carousel(style: "cascade", visible: 5))["data-carousel-visible"]
  end

  def test_cascade_refuses_a_visible_that_is_not_three_or_five
    [1, 4, 7, "5", :five].each do |visible|
      assert_match(/visible: .* is not 3 or 5/, cascade_refusal { render_carousel(style: :cascade, visible: visible) })
    end
  end

  def test_only_a_cascade_takes_visible
    [:standard, :spotlight].each do |style|
      assert_match(/only a style: :cascade row takes it/, cascade_refusal { render_carousel(style: style, visible: 5) })
    end
  end

  def test_cascade_opens_on_its_middle_slide_with_two_steps_each_side
    doc = render_carousel(items: SEVEN, style: :cascade)

    assert_equal %w[before -2 -1 0 1 2 after], steps(doc)
    assert_equal "3", current_dot(doc)
    assert_equal [3], doc.css(".carousel-slide").each_with_index.select { |slide, _| slide.key?("data-current") }.map(&:last)
    assert_equal "3", region(doc)["data-carousel-start"]
  end

  def test_cascade_takes_an_explicit_start
    doc = render_carousel(items: SEVEN, style: :cascade, start: 0)

    assert_equal %w[0 1 2 after after after after], steps(doc)
    assert_equal ["true", nil], arrows(doc), "Previous is off at the first slide"
    assert_equal %w[-2 -1 0 1 2 after after], steps(render_carousel(items: SEVEN, style: :cascade, start: 2))
  end

  def test_a_looping_cascade_opens_on_its_first_slide_with_the_last_two_on_its_left
    doc = render_carousel(items: SEVEN, style: :cascade, loop: true)

    assert_equal %w[0 1 2 after before -2 -1], steps(doc)
    assert_equal "0", current_dot(doc)
    assert_equal %w[false], arrows(doc).compact.uniq, "a looping row disables neither arrow"
  end

  def test_a_looping_cascade_breaks_the_far_tie_to_the_later_side
    four = SEVEN.first(4)

    assert_equal %w[0 1 2 -1], steps(render_carousel(items: four, style: :cascade, loop: true))
    assert_equal %w[-2 -1 0 1 2 after], steps(render_carousel(items: SEVEN.first(6), style: :cascade, loop: true, start: 2))
  end

  def test_a_cascade_caption_sits_under_the_body
    doc = render_carousel(style: :cascade, caption: ->(item) { "#{item.name}, live" })

    assert_equal %w[carousel-cascade-body carousel-caption], doc.at_css(".carousel-slide").element_children.map { |el| el["class"] }
    assert_equal ["Turf, live", "Cyvasse, live", "Rolio, live"], doc.css(".carousel-caption").map(&:text)
  end

  def test_a_cascade_of_none_or_one_renders
    assert_empty render_carousel(items: [], style: :cascade).css(".carousel-slide")
    assert_equal %w[0], steps(render_carousel(items: SEVEN.first(1), style: :cascade, loop: true))
  end

  def test_a_cascade_autoplays_with_the_pause_button
    doc = render_carousel(style: :cascade, autoplay: 5, loop: true)

    assert_equal "5", region(doc)["data-carousel-autoplay"]
    assert doc.at_css(".carousel-autoplay[aria-label='Pause slideshow']")
  end

  # The cascade lives beside the other styles, not in them: each renders byte for
  # byte what it rendered before the cascade was added. These digests were taken on
  # the release before it (0.137.0) and pin the whole output, so a change to the
  # standard or spotlight markup has to change them on purpose.
  BYTE_IDENTITY = [
    [ITEMS, {}],
    [ITEMS, { style: :standard, caption: ->(i) { "Cap #{i.name}" } }],
    [ITEMS, { style: :spotlight }],
    [SEVEN, { style: :spotlight, caption: ->(i) { "Cap #{i.name}" } }],
    [SEVEN, { style: :spotlight, loop: true, autoplay: 3.5, start: 1 }],
    [SEVEN, { start: :middle, per_view: 2.5, loop: true, slide_label: ->(i) { i.name } }]
  ].freeze
  BYTE_IDENTITY_DIGESTS = %w[3490a0179a62aa1a 202ca6983533a326 e6d195e03de08832 f221ee2dc38d062e b7634921dd03c65b 417bfdb4bb325e7f].freeze

  def raw(items, locals)
    view = ActionView::Base.with_empty_template_cache.new(ActionView::LookupContext.new([VIEWS]), {}, nil)
    view.render(layout: "studio/carousel", locals: { label: "Portfolio", items: items, **locals }) do |item|
      view.tag.a(item.name, href: "/#{item.name.downcase}", class: "card")
    end
  end

  def test_standard_and_spotlight_render_byte_for_byte_as_before_the_cascade
    digests = BYTE_IDENTITY.map { |items, locals| Digest::SHA256.hexdigest(raw(items, locals))[0, 16] }

    assert_equal BYTE_IDENTITY_DIGESTS, digests
  end

end
