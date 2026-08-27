# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# [unit] The two funding-modal primitives, extracted 2026-08-26 from
# turf-monster (extract-funding-modal-chrome).
#
# WHY THEY WERE WORTH EXTRACTING, in numbers measured off that app rather than
# estimated: the close × appeared BYTE-IDENTICAL in eight files, and the rail row
# ten times across three. Both are pure markup, which is exactly the kind of
# duplication that survives review — every copy looks right on its own.
#
# WHAT THESE TESTS DEFEND is therefore not "does it render" but the two contracts
# a copy-paste would quietly break: the rail row's emphasis is a RANKING carried
# by three signals at once, and the close × is positioned relative to an ancestor
# it cannot see.
class FundingChromeBlocksTest < Minitest::Test
  # --- close × ---------------------------------------------------------------

  def test_close_x_closes_the_default_store
    html = render_close_x

    assert_includes html, %($store.modals.close()), "the default store is `modals`"
    assert_includes html, %(aria-label="Close")
  end

  def test_close_x_can_be_pointed_at_another_store
    # The style guide runs its own page-scoped host (dsModals). Without this the
    # guide's copy of the card would call close() on an undefined store, inside a
    # click handler, where nothing surfaces the throw.
    html = render_close_x(modal_store: "dsModals")

    assert_includes html, %($store.dsModals.close())
    refute_includes html, %($store.modals.close()),
      "pointing the mark at another store must REPLACE the default, not add to it"
  end

  def test_close_x_is_absolutely_positioned
    # The whole reason this is a primitive and not a shell retrofit. If the class
    # ever loses `absolute`, the mark stops anchoring to its card and starts
    # flowing inline — a layout change no callsite would notice in review.
    assert_includes render_close_x, "absolute top-0 right-0"
  end

  # --- rail row --------------------------------------------------------------

  def test_rail_row_renders_its_documented_locals
    html = render_rail(title: "Coinbase", subtitle: "Card or bank",
                       icon_label: "C", icon_bg: "#0052FF",
                       on_click: "doThing()")

    assert_includes html, "Coinbase"
    assert_includes html, "Card or bank"
    assert_includes html, ">C<"
    assert_includes html, "background-color:#0052FF"
    assert_includes html, %(@click="doThing()")
  end

  # THE RANKING IS THE CONTRACT. Emphasis moves three things at once — the border
  # weight, the hover, and the chevron colour — because on a 56px row any one of
  # them alone is invisible. A callsite that could pass classes would eventually
  # apply one of the three; that is why it is a single named local, and why this
  # asserts all three rather than the one that is easiest to read.
  def test_primary_emphasis_moves_all_three_signals
    html = render_rail(emphasis: :primary)

    assert_includes html, "border-2 border-primary", "the doubled border"
    assert_includes html, "hover:bg-surface",        "the filled hover"
    assert_includes html, "w-4 h-4 text-primary",    "the coloured chevron"
  end

  def test_neutral_emphasis_moves_none_of_them
    html = render_rail(emphasis: :neutral)

    refute_includes html, "border-2 border-primary"
    refute_includes html, "hover:bg-surface"
    assert_includes html, "border border-strong", "neutral keeps the single border"
    assert_includes html, "w-4 h-4 text-muted",   "and the quiet chevron"
  end

  def test_neutral_is_the_default
    # Deliberate: a hub wants exactly ONE loud rail, so the default must be the
    # quiet one. Defaulting to :primary would make every row shout the moment a
    # callsite forgot the local.
    assert_equal render_rail(emphasis: :neutral), render_rail
  end

  # --- the two tile treatments ----------------------------------------------

  def test_a_brand_tile_carries_its_colour_inline
    # This is how a rail wears a processor's mark without the engine shipping an
    # asset for every processor an app might add.
    html = render_rail(icon_label: "CF", icon_bg: "#14B8A6")

    assert_includes html, "background-color:#14B8A6"
    refute_includes html, "bg-primary", "an explicit colour must not ALSO get the token background"
  end

  def test_a_tile_with_no_colour_falls_back_to_the_primary_token
    html = render_rail(icon_label: "S")

    assert_includes html, "bg-primary"
  end

  def test_an_emoji_tile_can_drop_the_bold_white_treatment
    # The default suits letters. An emoji under `text-white font-extrabold`
    # renders as a fuzzy white blob, so the local exists to turn it off.
    html = render_rail(icon_label: "🎟️", icon_class: "text-xl")

    assert_includes html, "text-xl"
    refute_includes html, "font-extrabold"
  end

  # --- :soon, the announced-but-not-wired rail -------------------------------
  #
  # FOUND WHILE BUILDING THE SPECIMENS, not from the spec. The first cut of this
  # primitive covered eight of the ten copies; turf's onramp hub announces PayPal
  # and Venmo with a THIRD shape, and a rail_row that could not express it would
  # have left two hand-rolled copies behind in the file the extraction was for.

  def test_a_soon_rail_is_not_interactive_at_all
    html = render_rail(state: :soon, title: "PayPal")

    assert_includes html, "<div", "a :soon rail is a div"
    refute_includes html, "<button", "not a disabled button — no focus stop, no pointer"
    refute_includes html, "@click", "and nothing to fire"
  end

  def test_a_soon_rail_needs_no_click_handler
    # on_click is fetched unconditionally for an available rail. Requiring it for
    # a placeholder would make every announcement invent a no-op.
    view.render(partial: "studio/modals/blocks/rail_row",
                locals: { title: "Venmo", state: :soon })
  end

  def test_a_soon_rail_replaces_the_chevron_rather_than_dimming_it
    # A chevron says "this goes somewhere", which is the one thing this row must
    # not say. So the badge takes its place instead of sitting beside it.
    html = render_rail(state: :soon)

    assert_includes html, ">Soon<"
    refute_includes html, "M8.25 4.5l7.5 7.5-7.5 7.5", "the chevron path must be gone"
  end

  def test_a_soon_rail_is_dimmed_and_quietly_bordered
    html = render_rail(state: :soon)

    assert_includes html, "opacity-60"
    assert_includes html, "border border-subtle"
    refute_includes html, "hover:", "nothing about it may respond to a pointer"
  end

  def test_the_soon_label_is_the_callers_word
    assert_includes render_rail(state: :soon, soon_label: "Waitlist"), ">Waitlist<"
  end

  def test_available_is_the_default_state
    assert_equal render_rail(state: :available), render_rail
  end

  # --- the optional bits drop rather than render empty ----------------------

  def test_the_badge_is_dropped_when_absent
    with_badge = render_rail(badge: "New")
    without    = render_rail

    assert_includes with_badge, "New"
    refute_includes without, "rounded-full px-2 py-0.5",
      "no badge must mean no pill, not an empty one"
  end

  def test_the_subtitle_is_dropped_when_absent
    refute_includes render_rail(subtitle: nil), "text-xs text-secondary"
  end

  # --- the handler is CODE, not content ---------------------------------------

  # --- the DOM, not a substring ----------------------------------------------
  #
  # EVERY ASSERTION IN THIS FILE USED TO BE assert_includes, and that blind spot
  # let two defects through in a row: the escaped handler in #200, and then a
  # rewrite of the fix that emitted a malformed element and leaked template text
  # into every rail. Both render a string that CONTAINS the substring being
  # asserted. Parse the markup instead — element name, resolvable hook, sibling
  # count — because those are the properties a substring cannot see.

  def test_a_soon_rail_with_data_is_a_well_formed_element
    # The regression this exists for: an attribute helper that strips its leading
    # space produced <divdata-ds-rail="paypal">. HTML5's tag-name state accepts
    # = and " into the NAME, so the element was called divdata-ds-rail="paypal",
    # the hook resolved to nothing, and </div> matched nothing — the element
    # never closed and swallowed every rail after it.
    frag = fragment(render_rail(state: :soon, data: { ds_rail: "paypal" }))

    assert_equal "div", frag.element_children.first&.name
    assert_equal 1, frag.css("[data-ds-rail=paypal]").size, "the hook must resolve"
    assert_equal 1, frag.element_children.size, "and the rail must be a single root"
  end

  def test_adjacent_soon_rails_stay_siblings
    # The onramp hub renders PayPal and Venmo back to back. An unclosed element
    # nests the second inside the first and takes its hook with it.
    frag = fragment(render_rail(state: :soon, data: { ds_rail: "paypal" }) +
                    render_rail(state: :soon, data: { ds_rail: "venmo" }))

    assert_equal 2, frag.element_children.size, "two rails, two roots"
    assert_equal 2, frag.css("[data-ds-rail]").size, "two rails, two hooks"
  end

  def test_the_rail_emits_no_stray_template_text
    # An ERB comment terminates at the FIRST %>, so a comment whose body contains
    # one spills the remainder into the template as visible text — at the top of
    # every rail, in both branches, six times over on the onramp hub specimen.
    stray = fragment(render_rail(on_click: "noop()"))
              .children.select { |n| n.text? && n.text.strip != "" }

    assert_empty stray.map { |n| n.text.strip },
      "a rail must render markup only"
  end

  def test_a_double_quoted_expression_still_works
    # html_safe stops content_tag ENTITY-escaping the handler, but content_tag
    # still quote-escapes an attribute VALUE — so a double-quoted expression is
    # encoded and the browser hands Alpine the original. An earlier fix emitted
    # the handler through `raw` in literal ERB, which had no such protection: it
    # broke out of the attribute and narrowed the contract to single quotes.
    el = fragment(render_rail(on_click: %(f("a")))).element_children.first

    assert_equal %(f("a")), el["@click"],
      "the handler must survive the round trip, whichever quotes the caller used"
  end

  def test_a_quoted_alpine_expression_survives_unescaped
    # THE REGRESSION THIS FILE MISSED. The first cut built the element with
    # content_tag, which escapes every attribute value — right for content, wrong
    # for code. An Alpine handler came out as f(&#39;a&#39;) instead of f('a').
    #
    # A BROWSER STILL FIRED IT, which is why it shipped: the HTML parser
    # unescapes the attribute before Alpine ever calls getAttribute. What broke
    # was everything that reads the MARKUP — eight assertions across three
    # turf-monster suites, each asserting the raw handler string, and each of
    # them right to.
    html = render_rail(on_click: "tmCoinflowBuyOne('single')")

    assert_includes html, %(@click="tmCoinflowBuyOne('single')"),
      "the handler must reach the attribute exactly as the caller wrote it"
    refute_includes html, "&#39;",
      "a primitive that mangles the expression it was handed is lying about what it renders"
  end

  def test_content_locals_are_still_escaped
    # The other half of the same contract: title and subtitle are CONTENT, and a
    # caller passing a quote or a bracket must not be able to reshape the markup.
    html = render_rail(title: %(Coinflow "fast" <b>), subtitle: "a & b")

    assert_includes html, "&quot;fast&quot;"
    assert_includes html, "&lt;b&gt;"
    assert_includes html, "a &amp; b"
  end

  def test_data_attributes_reach_the_button
    # The app's own test hooks (turf uses data-onramp-rail / data-buy-rail /
    # data-topup-rail). Underscores become dashes, which is the Rails convention
    # a caller will assume.
    html = render_rail(data: { onramp_rail: "coinbase" })

    assert_includes html, %(data-onramp-rail="coinbase")
  end

  def test_no_data_attribute_is_emitted_when_none_is_given
    refute_includes render_rail, "data-"
  end

  private

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
  end

  def render_close_x(**locals)
    view.render(partial: "studio/modals/blocks/close_x", locals: locals)
  end

  # Only on_click and title are required by the partial; everything else is
  # optional, so the defaults here keep each test naming ONLY what it is about.
  def fragment(html)
    Nokogiri::HTML5.fragment(html)
  end

  def render_rail(**locals)
    view.render(partial: "studio/modals/blocks/rail_row",
                locals: { on_click: "noop()", title: "A rail" }.merge(locals))
  end
end
