# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# [component] components/_geo_signpost — the geo row itself, rendered directly
# rather than through one of its two chromes.
#
# WHY THIS FILE EXISTS. The row shipped in 0.58.0 as a block INSIDE
# components/_admin_dropdown, on the premise that the shared dropdown reaches
# every app. It reached one of three: a sidebar-chrome app suppresses the
# dropdown (studio_sidebar_replaces_admin_menu?) and a forked-chrome app renders
# neither. Extracting the row gave the policy one home; these tests pin that ONE
# home behaves identically in both variants, because two chromes quietly
# disagreeing about whether geo is reachable is the failure this refactor is for.
class GeoSignpostTest < Minitest::Test
  VARIANTS = %i[dropdown sidebar].freeze

  # --- the admin gate, in BOTH chromes ---------------------------------------
  #
  # Self-gated in the partial rather than in each caller. The dropdown shipped
  # without a gate once and offered admin links to signed-out strangers on a
  # public page; a second caller doubles the chances of that being forgotten.

  def test_renders_nothing_for_a_viewer_without_the_admin_predicate
    VARIANTS.each do |variant|
      assert_empty render_signpost(variant: variant, admin: nil).strip,
                   "#{variant}: bare viewers (no admin?) must see no geo row"
    end
  end

  def test_renders_nothing_for_a_non_admin
    VARIANTS.each do |variant|
      assert_empty render_signpost(variant: variant, admin: false, geo_flag: true, geo_routes: true).strip,
                   "#{variant}: non-admins must see no geo row"
    end
  end

  # --- the three states, in BOTH chromes -------------------------------------

  def test_links_the_manager_when_the_flag_and_the_routes_are_both_there
    VARIANTS.each do |variant|
      html = render_signpost(variant: variant, admin: true, geo_flag: true, geo_routes: true)

      assert_includes html, "/admin/geo", "#{variant}: an app with geo on gets a live link"
      refute_includes html, "geo-signpost-disabled", "#{variant}: a live row is not a disabled one"
    end
  end

  def test_is_disabled_and_names_the_variable_when_the_flag_is_off
    VARIANTS.each do |variant|
      html = render_signpost(variant: variant, admin: true, geo_flag: false, geo_routes: true)

      assert_includes html, "geo-signpost-disabled", "#{variant}: the row stays, disabled"
      assert_includes html, "ENABLE_GEO_BLOCKING", "#{variant}: it must say what to set"
      refute_includes html, "/admin/geo", "#{variant}: and must not link a page it says is off"
    end
  end

  # THE RAISE THIS AVOIDS, now in two places instead of one. Where the host never
  # drew the geo routes, `admin_geo_path` is not defined at all — a disabled
  # branch that reached for it would take down admin chrome on EVERY page. The
  # sidebar variant inherits that hazard the moment it renders in a second app.
  def test_is_disabled_without_reaching_for_a_route_that_does_not_exist
    VARIANTS.each do |variant|
      html = render_signpost(variant: variant, admin: true, geo_flag: true, geo_routes: false)

      assert_includes html, "geo-signpost-disabled", "#{variant}: renders rather than raising"
      assert_includes html, "Draw the geo routes first", "#{variant}: names the other prerequisite"
      refute_includes html, "/admin/geo"
    end
  end

  # Both chromes agree on the WORDS, not merely on being disabled. The signage is
  # the feature — an operator reading "Draw the geo routes first" in one app and
  # something vaguer in another learns less than the dropdown taught alone.
  def test_both_variants_carry_the_same_signage
    [[true, "ENABLE_GEO_BLOCKING"], [false, "Draw the geo routes first"]].each do |routes, phrase|
      rendered = VARIANTS.to_h do |variant|
        [variant, render_signpost(variant: variant, admin: true, geo_flag: false, geo_routes: routes)]
      end

      rendered.each { |variant, html| assert_includes html, phrase, "#{variant}: missing the shared signage" }
      assert_equal rendered[:dropdown].scan(/title="([^"]*)"/), rendered[:sidebar].scan(/title="([^"]*)"/),
                   "the hover title is the long-form instruction; both chromes must give the same one"
    end
  end

  # --- the chrome seam -------------------------------------------------------

  # The panel a row lives in closes behind it, and the flag belongs to the
  # CALLER: the engine link sidebar drives $store.sidebars.linkTreeOpen, while
  # turf-monster's forked gear sidebar drives gearOpen. A partial that hardcoded
  # either one would leave the other's panel hanging open, so it takes the
  # expression as a local — this is the seam a forked chrome adopts through.
  def test_the_close_action_is_the_callers_own_expression
    html = render_signpost(variant: :sidebar, admin: true, geo_flag: true, geo_routes: true,
                           close_action: "$store.sidebars.gearOpen = false")

    assert_includes html, "$store.sidebars.gearOpen = false"
  end

  def test_no_close_action_emits_no_click_handler
    html = render_signpost(variant: :sidebar, admin: true, geo_flag: true, geo_routes: true)

    refute_includes html, "@click", "an unpassed close_action must not leave a dangling handler"
  end

  # The default is the dropdown, so the 0.58.0 call site keeps rendering the row
  # it always did without naming a variant.
  def test_the_default_variant_is_the_dropdown
    bare    = render_signpost(admin: true, geo_flag: true, geo_routes: true)
    named   = render_signpost(variant: :dropdown, admin: true, geo_flag: true, geo_routes: true)

    assert_equal named, bare
  end

  # --- operator ergonomics on the disabled row -------------------------------
  #
  # The disabled row is not decoration: it is the ONLY place the engine hands an
  # operator the string that turns geo on. These pin that it can actually be
  # read, copied, and announced.

  # OVERFLOW. The machine string is one unbreakable token — no spaces, and
  # neither "_" nor "=" is a break opportunity — and as one run of text it
  # painted ~28px past the w-44 dropdown's right border. It is its own element
  # now so the break class lands on it ALONE, leaving prose to wrap normally.
  def test_the_machine_string_is_its_own_breakable_element
    VARIANTS.each do |variant|
      [true, false].each do |routes|
        node = Nokogiri::HTML5.fragment(
          render_signpost(variant: variant, admin: true, geo_flag: false, geo_routes: routes)
        ).at_css("[data-test='geo-signpost-disabled'] code")

        refute_nil node, "#{variant}/routes=#{routes}: the copyable string must be its own element"
        assert_includes node["class"].to_s.split, "break-all",
                        "#{variant}/routes=#{routes}: an unbreakable token needs the break class ON IT"
        refute_includes node.text, " the ", "#{variant}/routes=#{routes}: prose must stay outside the break-all"
      end
    end
  end

  # SELECT. select-none on the outer span made the very string the row exists to
  # hand over impossible to select with a mouse.
  def test_the_disabled_row_does_not_block_selecting_its_string
    VARIANTS.each do |variant|
      html = render_signpost(variant: variant, admin: true, geo_flag: false, geo_routes: true)

      refute_includes html, "select-none",
                       "#{variant}: the row's whole job is handing over a string to copy"
    end
  end

  # A11Y. A bare span announces as plain text, so a screen reader gets no hint
  # that this is a destination and that the destination is unavailable.
  def test_the_disabled_row_announces_itself_as_an_unavailable_destination
    VARIANTS.each do |variant|
      node = Nokogiri::HTML5.fragment(
        render_signpost(variant: variant, admin: true, geo_flag: false, geo_routes: true)
      ).at_css("[data-test='geo-signpost-disabled']")

      assert_equal "true", node["aria-disabled"], "#{variant}: a disabled control must say so"
      assert_equal "link", node["role"], "#{variant}: it is a destination, not a paragraph"
    end
  end

  # A11Y, second half. The initializer line lived ONLY in the title attribute,
  # which is mouse-only — invisible on touch, where an operator is just as likely
  # to be reading this. Strip every attribute and it must still be on the page.
  def test_the_initializer_line_is_visible_not_only_on_hover
    VARIANTS.each do |variant|
      node = Nokogiri::HTML5.fragment(
        render_signpost(variant: variant, admin: true, geo_flag: false, geo_routes: false)
      ).at_css("[data-test='geo-signpost-disabled']")
      node.traverse { |n| n.attribute_nodes.each(&:remove) if n.element? }

      assert_includes node.text, "config.draw_geo_routes = true",
                      "#{variant}: the fix must be readable without a mouse"
    end
  end

  # THE RAISE A `fetch` DEFAULT DOES NOT CATCH. fetch only defaults an ABSENT
  # key, so a caller computing the variant inline — `variant: sidebar? &&
  # :sidebar` — passes an explicit nil, and `nil.to_sym` took down admin chrome
  # on every page of that app.
  def test_an_explicit_nil_variant_falls_back_to_the_dropdown
    explicit = render_signpost(admin: true, geo_flag: true, geo_routes: true, variant: nil, pass_variant: true)

    assert_equal render_signpost(variant: :dropdown, admin: true, geo_flag: true, geo_routes: true), explicit
  end

  private

  def render_signpost(admin:, variant: nil, geo_flag: nil, geo_routes: false, close_action: nil, pass_variant: false)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.define_singleton_method(:admin?) { admin } unless admin.nil?
    # The host's route helper, present only where the app drew the geo routes.
    view.define_singleton_method(:admin_geo_path) { "/admin/geo" } if geo_routes

    locals = {}
    locals[:variant] = variant if variant || pass_variant
    locals[:close_action] = close_action if close_action

    previous = Studio.geo_blocking_enabled
    Studio.geo_blocking_enabled = geo_flag
    view.render(partial: "components/geo_signpost", locals: locals)
  ensure
    Studio.geo_blocking_enabled = previous
  end
end
