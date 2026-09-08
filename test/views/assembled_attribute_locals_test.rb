# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] Host locals spliced into an attribute that the PARTIAL ASSEMBLED BY
# HAND — quotes and all — and then marked html_safe.
#
# THIS IS A DIFFERENT DEFECT FROM test/views/js_attribute_locals_test.rb, and worse.
# There the local sat inside a JS string literal, a stray apostrophe closed the
# LITERAL, and Alpine mounted a no-op — silent, but contained. Here the partial wrote
# the attribute's own quotes into a Ruby String and marked it safe, so ERB's
# attribute escaping never ran at all: a double quote in the local closed the
# ATTRIBUTE and everything after it was parsed as MARKUP. Measured on the
# unrepaired templates, one hostile local turned
#
#     x-data="{ _remaining: 4242, … }" class="text-center py-6"
#
# into an element carrying attributes named `quote"`, `\`, `<` and `script`, with the
# class attribute swallowed entirely.
#
# HOW THIS FILE HAS TO ASSERT. The trap that made the first draft of the sibling file
# inert applies here with full force and one extra twist:
#
#   1. "the hostile value appears in the markup" cannot fail on a REPAIRED site and
#      cannot pass on a broken one for the right reason — the raw bytes differ from
#      what the browser holds either way.
#   2. A structural check on the RAW markup cannot fail at all, because ERB
#      entity-escapes an unmarked value too. Four mutants survived exactly that
#      assertion in the sibling sweep.
#
# So every seam here is read through Nokogiri's HTML5 parser — the same algorithm a
# browser runs — and asserted on the DECODED attribute value it hands back, never on
# the template's output bytes. HTML5 rather than HTML4 on purpose: HTML4 SILENTLY
# DROPS an `@click` (`@` cannot begin an XML name), so every Alpine assertion made
# through it reads nil on a perfectly correct page and can never fail.
#
# EACH SEAM MAKES TWO CLAIMS, and it takes both to pin the defect:
#
#   SHAPE — the element carries exactly the attributes it carries under a benign
#           value. This is the injection half; it goes red the moment a value breaks
#           out and the parser invents attributes from the remainder. It is written
#           as a benign-vs-hostile comparison rather than a hard-coded list so that
#           adding an attribute to a partial never reddens twelve tests for the
#           wrong reason.
#   VALUE — the browser recovers the benign expression with the benign token swapped
#           for the hostile one, and nothing else. This is the truncation half; on a
#           broken seam the value stops at the host's own double quote.
#
# WHAT IS DELIBERATELY *NOT* CLAIMED. The sibling file can hand its recovered string
# to a JS-literal reader and prove a JS parser gets the value back, because there the
# local IS a string literal. These locals are EXPRESSION fragments — an Alpine
# handler, a countdown URL key, a JS number — so the honest strongest claim is the
# one above: the full expression the template composed reaches the browser as one
# attribute. Whether that expression then means anything is the caller's contract.
# The browser half — that the card mounts and the handler fires — is
# e2e/js_attribute_locals.spec.js.
class AssembledAttributeLocalsTest < ActiveSupport::TestCase
  # Appended to a benign value to make it hostile. Every character that could leave
  # the nest of contexts: the apostrophe that would close a JS literal, the double
  # quote that closes the HTML attribute once ERB has been persuaded to skip its
  # half, a backslash, and a closing script tag.
  HOSTILE_TAIL = %q{ it's a "quote" \ </script>}

  def render_partial(name, **locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(Studio::Engine.helpers)
    view.render(partial: name, locals: locals)
  end

  # The element as a BROWSER holds it, not as the template wrote it.
  def parse(html, &selector)
    selector.call(Nokogiri::HTML5.fragment(html))
  end

  # One seam: render the partial twice, benign and hostile, and hold the hostile
  # render to the benign one.
  def assert_seam_encoded(partial:, locals:, local:, benign:, attr:, seam:, &selector)
    hostile = "#{benign}#{HOSTILE_TAIL}"

    benign_el  = parse(render_partial(partial, **locals.merge(local => benign)), &selector)
    hostile_el = parse(render_partial(partial, **locals.merge(local => hostile)), &selector)

    refute_nil benign_el, "#{seam}: the benign render produced no element to compare against"
    refute_nil hostile_el, "#{seam}: the hostile render produced no element — the tag itself broke"

    # NON-VACUITY, and it is not decoration. Both claims below are written as
    # benign-vs-hostile comparisons, so a template that stopped interpolating the
    # local ENTIRELY would satisfy them trivially: the two renders would be
    # identical and the swap would be a no-op. Measured — hardcoding
    # min_duration's value left this seam's test green and only the separate
    # inertness test noticed. This line is the control that makes every seam
    # below prove it is actually reading the local it names.
    assert_includes benign_el[attr].to_s, benign.to_s,
      "#{seam}: #{local} does not reach #{attr} at all, so everything asserted about " \
      "it here would pass on a template that never splices it"

    assert_equal benign_el.attribute_nodes.map(&:name), hostile_el.attribute_nodes.map(&:name),
      "#{seam}: a hostile #{local} changed which ATTRIBUTES the element carries, so the value " \
      "broke out of #{attr} and the remainder was parsed as markup"

    assert_equal benign_el[attr].to_s.gsub(benign.to_s, hostile), hostile_el[attr],
      "#{seam}: the browser recovers #{hostile_el[attr].inspect} from #{attr}, so the " \
      "expression the template composed did not survive intact"
  end

  # --- blocks/_success_card: a Ruby-built x-data object and an x-init call list ---
  #
  # The engine's most-rendered block, and the widest reach this failure has. Both
  # attributes are assembled in Ruby and both are html_safe; they are driven
  # SEPARATELY because they interpolate different locals on different lines and a
  # repair applied to one is silent about the other.

  test "a hostile auto_redirect_seconds cannot break out of the success card's x-data" do
    assert_seam_encoded(
      partial: "studio/modals/blocks/success_card",
      locals: { title: "Done", cta_label: "Go", auto_redirect_url_key: "props.url" },
      local: :auto_redirect_seconds, benign: 4242, attr: "x-data",
      seam: "the success card's countdown object"
    ) { |frag| frag.at_css("div[x-data]") }
  end

  test "a hostile auto_redirect_url_key cannot break out of the success card's x-init" do
    assert_seam_encoded(
      partial: "studio/modals/blocks/success_card",
      locals: { title: "Done", cta_label: "Go" },
      local: :auto_redirect_url_key, benign: "props.zqRedirectUrl", attr: "x-init",
      seam: "the success card's startCountdown call"
    ) { |frag| frag.at_css("div[x-init]") }
  end

  # --- blocks/_processing_card: one assembled pair, TWO interpolated locals -------
  #
  # min_duration is driven on its own because it LOOKS numeric and is not: only the
  # guard calls .to_i, the interpolation splices the local raw. A repair that only
  # thought about resolve_expr leaves this half open.

  test "a hostile resolve_expr cannot break out of the processing card's x-init" do
    assert_seam_encoded(
      partial: "studio/modals/blocks/processing_card",
      locals: { title: "Working" },
      local: :resolve_expr, benign: "zqResolve()", attr: "x-init",
      seam: "the processing card's auto-resolve expression"
    ) { |frag| frag.at_css("div[x-init]") }
  end

  test "a hostile min_duration cannot break out of the processing card's x-init" do
    assert_seam_encoded(
      partial: "studio/modals/blocks/processing_card",
      locals: { title: "Working", resolve_expr: "zqResolve()" },
      local: :min_duration, benign: 4242, attr: "x-init",
      seam: "the processing card's holdAtLeast floor"
    ) { |frag| frag.at_css("div[x-init]") }
  end

  # --- blocks/_leveling_activity: the Next Quest handler --------------------------

  test "a hostile next_open cannot break out of the leveling activity's @click" do
    assert_seam_encoded(
      partial: "studio/modals/blocks/leveling_activity",
      locals: { submit_url: "/q", title: "Quest", leveling: true, next_label: "Next" },
      local: :next_open, benign: "zqOpenNext()", attr: "@click",
      seam: "the leveling activity's Next Quest button"
    ) { |frag| frag.at_css(%(template[x-if="celebrate && leveling"] button.btn-primary)) }
  end

  # --- blocks/_leveling_activity: the four input constraint attributes ------------
  #
  # SAME SHAPE, DIFFERENT FAMILY — not JS-evaluating, but assembled with their own
  # quotes and marked html_safe exactly like the handlers above, in the same file. A
  # double quote in any of the four closes the attribute and injects markup into a
  # form. Each is driven separately: they are four independent interpolations and one
  # test covering the input as a whole would go green the moment any one was fixed.

  { min_length: ["minlength", 4242, "the input's minimum length"],
    max_length: ["maxlength", 4243, "the input's maximum length"],
    pattern: ["pattern", "zqPattern", "the input's validation pattern"],
    pattern_title: ["title", "zqPatternTitle", "the input's constraint tooltip"] }.each do |local, (attr, benign, seam)|
    test "a hostile #{local} cannot break out of the leveling activity's #{attr}" do
      assert_seam_encoded(
        partial: "studio/modals/blocks/leveling_activity",
        locals: { submit_url: "/q", title: "Quest", input: true },
        local: local, benign: benign, attr: attr, seam: seam
      ) { |frag| frag.at_css("input[x-model=value]") }
    end
  end

  # --- components/_sidebar_panel: the three dismissal handlers --------------------
  #
  # All three were built as %(@name="#{action}").html_safe — the attribute's own
  # quotes assembled in Ruby — on the panel's ROOT element, so a break-out there
  # rewrites the shell every link menu in the ecosystem hangs from. Driven separately
  # because they are three lines; the shared call site passes the same expression to
  # all three, which is exactly how a one-line repair would look complete.

  { outside_action: ["@click.outside", "the panel's click-outside dismissal"],
    escape_action: ["@keydown.escape.window", "the panel's escape-key dismissal"],
    close_action: ["@turbo:before-cache.window", "the panel's turbo-cache dismissal"] }
    .each do |local, (attr, seam)|
    test "a hostile #{local} cannot break out of the sidebar panel's #{attr}" do
      assert_seam_encoded(
        partial: "components/sidebar_panel",
        locals: { open: "$store.sidebars.zqOpen", title: "Links" },
        local: local, benign: "$store.sidebars.zqOpen = false", attr: attr, seam: seam
      ) { |frag| frag.at_css("aside") }
    end
  end

  # --- THE INERTNESS CLAIM -------------------------------------------------------

  test "every repaired seam renders byte-for-byte what it rendered before" do
    # No default or in-repo value contains a character tag encoding touches, so this
    # change moved nothing on any shipped page. Asserted on the RAW output on
    # purpose — this is the one claim the source bytes are the right evidence for,
    # and it is what a consumer test reading this markup would see.
    success = render_partial("studio/modals/blocks/success_card",
                             title: "Done", cta_label: "Go",
                             auto_redirect_url_key: "props.redirectUrl",
                             auto_redirect_seconds: 7, confetti: true)
    assert_includes success, %q{x-init="fireConfetti(); startCountdown(props.redirectUrl)"}
    assert_includes success, %q[<div x-data="{ _remaining: 7, _total: 7, _redirectTimer: null,]

    processing = render_partial("studio/modals/blocks/processing_card",
                                title: "Working", resolve_expr: "zqResolve()", min_duration: 900)
    assert_includes processing,
      %q{<div class="text-center py-6" x-data="{}" x-init="window.StudioModals.holdAtLeast(900).then(() => { zqResolve() })">}

    leveling = render_partial("studio/modals/blocks/leveling_activity",
                              submit_url: "/q", title: "Quest", input: true, min_length: 3,
                              max_length: 40, pattern: "[A-Za-z ]+", pattern_title: "Letters only",
                              leveling: true, next_label: "Next", next_open: "zqOpenNext()")
    assert_includes leveling, %q{minlength="3"}
    assert_includes leveling, %q{maxlength="40"}
    assert_includes leveling, %q{pattern="[A-Za-z ]+"}
    assert_includes leveling, %q{title="Letters only"}
    assert_includes leveling, %q{@click="zqOpenNext()"}

    sidebar = render_partial("components/sidebar_panel", open: "$store.sidebars.open",
                             title: "Links", close_action: "$store.sidebars.open = false",
                             outside_action: "$store.sidebars.open = false",
                             escape_action: "$store.sidebars.open = false")
    assert_includes sidebar, %q{@click.outside="$store.sidebars.open = false"}
    assert_includes sidebar, %q{@keydown.escape.window="$store.sidebars.open = false"}
    assert_includes sidebar, %q{@turbo:before-cache.window="$store.sidebars.open = false"}
  end
end
