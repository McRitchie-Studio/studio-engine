# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

# [unit] The two /admin/modals sections that review ENGINE behaviour, now owned
# by the living style guide: the enter/leave animation simulator and the stack
# behaviour demos.
#
# WHY THIS FILE EXISTS. turf-monster's /admin/modals gallery is being deleted.
# Two of its sections were not consumer showroom at all — they exercised engine
# mechanics (the window.ModalAnimations registry, the modal stack's
# dismissibility / hold-at-least / LIFO rules) and would have gone with it. They
# now live in app/views/style/_modals.html.erb, and these assertions pin the two
# properties that are easy to lose in a later edit.
#
# THE PORT'S ONE HAZARD. Roughly half of turf's stack demos drove
# Alpine.store('solanaModal') — turf's LEGACY COMPATIBILITY PROXY, which this
# engine has no equivalent of. A copy-paste port would leave dead references
# that fail silently in the browser (Alpine.store returns undefined; the click
# throws into the console and the operator sees a dead button). test_stack_demos
# _do_not_reference_the_legacy_turf_store is the guard against that.
class StyleGuideModalSimulatorTest < ActiveSupport::TestCase
  GUIDE = File.expand_path("../../app/views/style/_modals.html.erb", __dir__)

  def source = File.read(GUIDE)

  # --- The markup renders -------------------------------------------------

  def test_both_ported_sections_are_present_and_anchored
    missing = %w[modals-motion-registry modals-stack-mechanics]
              .reject { |id| source.include?(%(<section id="#{id}" class="space-y-5">)) }

    assert_empty missing,
                 "these ported sections are gone from the guide: #{missing.inspect}. They are " \
                 "the two /admin/modals sections that review ENGINE behaviour, so losing them " \
                 "loses the capability turf-monster's gallery deletion was allowed to assume."
  end

  # The four containers the simulator's build script writes into. A renamed id
  # here is the silent failure mode: the script's getElementById returns null,
  # every addButton/addOption returns early, and the section renders as four
  # empty boxes with no error anywhere.
  SIMULATOR_TARGET_IDS = %w[
    modal-anim-enter-buttons
    modal-anim-exit-buttons
    modal-anim-enter-select
    modal-anim-exit-select
  ].freeze

  def test_simulator_control_containers_exist_for_the_script_to_fill
    section = section_dom("modals-motion-registry")

    missing = SIMULATOR_TARGET_IDS.reject { |id| section.at_css("##{id}") }

    assert_empty missing,
                 "the simulator script writes its generated controls into #{missing.inspect}, " \
                 "which the markup no longer defines. getElementById would return null and the " \
                 "section would render as empty boxes with nothing logged."
  end

  # --- The controls are GENERATED, not hard-coded --------------------------

  # THE PROPERTY THE SECTION EXISTS FOR. The whole point of building the controls
  # from window.ModalAnimations is that registering a new animation surfaces it
  # here with no edit to this page. Hard-coding even one button silently breaks
  # that: the page keeps working, and simply never grows the new key.
  #
  # Proven two ways, because either alone is weak. First: the containers ship
  # EMPTY, so every control in them came from the script.
  def test_simulator_containers_ship_empty_so_every_control_is_generated
    section = section_dom("modals-motion-registry")

    hard_coded = SIMULATOR_TARGET_IDS.filter_map do |id|
      node = section.at_css("##{id}")
      next if node.nil?

      "#{id} (#{node.element_children.length} child element(s))" if node.element_children.any?
    end

    assert_empty hard_coded,
                 "these simulator containers ship with markup already inside them: " \
                 "#{hard_coded.inspect}. They must be empty — a hard-coded control is one the " \
                 "registry does not govern, so a newly registered animation would never appear " \
                 "beside it and nothing would report the gap."
  end

  # Second: the script actually READS the registry to build them. An empty
  # container plus a script that enumerates a local literal would pass the
  # assertion above while losing the property entirely.
  def test_simulator_builds_its_controls_by_enumerating_the_live_registry
    script = simulator_script

    assert_match(/Object\.keys\(reg\.enter/, script,
                 "the simulator no longer enumerates the ENTER side of the registry. Controls " \
                 "built from anything but window.ModalAnimations stop tracking it.")
    assert_match(/Object\.keys\(reg\.exit/, script,
                 "the simulator no longer enumerates the EXIT side of the registry.")
    assert_match(/var reg = window\.ModalAnimations/, script,
                 "the simulator's control build no longer reads window.ModalAnimations, so its " \
                 "controls have stopped tracking the live registry.")
  end

  # The store must resolve animation keys through the LIVE registry too. This is
  # the half that makes the simulator honest rather than merely well-populated:
  # the guide's page-scoped store once carried a hard-coded copy of the animation
  # table, so a newly registered key grew a button (from the registry) that
  # resolved to 'pop' (from the stale copy). The control said one thing and the
  # card did another, with nothing reporting the difference.
  def test_page_store_resolves_animations_through_the_live_registry
    assert_match(/function modalAnim\(channel, key\) \{\s*var table = \(window\.ModalAnimations/m,
                 source,
                 "the guide's modalAnim no longer reads window.ModalAnimations at call time. A " \
                 "local animation table makes the generated controls lie: the button appears " \
                 "from the registry and the card falls back to 'pop'.")
  end

  # --- No dead references to turf's legacy proxy --------------------------

  # Alpine.store('solanaModal') is turf-monster's legacy compatibility proxy over
  # its own modal store. This engine ships NO such store, so any surviving
  # reference is a dead button: Alpine.store returns undefined and the handler
  # throws where only the console sees it.
  #
  # Matched case-sensitively and on the bare identifier. The guide legitimately
  # ships `dsSolanaModal` (capital S), which does NOT contain the lowercase
  # `solanaModal` this looks for — the distinction is the whole reason this
  # asserts on the exact spellings rather than a loose substring.
  LEGACY_STORE_PATTERNS = [
    /Alpine\.store\(\s*['"]solanaModal['"]\s*\)/,
    /\$store\.solanaModal\b/
  ].freeze

  def test_stack_demos_do_not_reference_the_legacy_turf_store
    offenders = LEGACY_STORE_PATTERNS.flat_map { |re| source.scan(re) }

    assert_empty offenders,
                 "the guide references Alpine.store('solanaModal'), turf-monster's legacy " \
                 "compatibility proxy. This engine registers no such store, so each reference " \
                 "is a button that throws instead of opening a modal. Drive $store.dsModals " \
                 "and the onchain-tx specimen directly."
  end

  # The guard above only bites if it is reading the demo code at all. If the
  # drivers are moved to another file, it would pass forever on a guide that no
  # longer contains them.
  def test_the_legacy_store_guard_reads_the_demo_drivers
    assert_match(/window\.dsModalDemos = /, source,
                 "the stack-behaviour demo drivers are no longer defined in this file, so " \
                 "test_stack_demos_do_not_reference_the_legacy_turf_store is now scanning a " \
                 "file that could not contain the reference it forbids.")
  end

  # And the demos must actually drive the page-scoped store, which is the
  # positive half of the same property.
  def test_stack_demos_drive_the_page_scoped_store
    drivers = demo_driver_script

    assert_match(/Alpine\.store\(['"]dsModals['"]\)/, drivers,
                 "the demo drivers no longer reach $store.dsModals — the page-scoped store the " \
                 "whole guide is built on.")
    assert_match(/store\(\)\.open\(['"]onchain-tx['"]/, drivers,
                 "the stack demos no longer open the onchain-tx specimen, which is the card " \
                 "they were rewritten against when turf's proxy was dropped.")
  end

  private

  # The <script> element carrying the demo drivers + the simulator build. Isolated
  # so the assertions above read the ported code specifically rather than the
  # whole 2000-line guide, where an unrelated match elsewhere could satisfy them.
  def demo_driver_script
    marker = "window.dsModalDemos = "
    start  = source.index(marker)
    refute_nil start, "no script in the guide defines window.dsModalDemos"

    finish = source.index("</script>", start)
    refute_nil finish, "the script defining window.dsModalDemos is never closed"

    source[start...finish]
  end
  alias simulator_script demo_driver_script

  # The source of ONE guide subsection, parsed on its own.
  #
  # The whole file cannot be DOM-parsed: it is ERB, and its <template x-if>
  # overlay swallows every following tag, so Nokogiri reports exactly one
  # <section> for a file that has ten. (test_ids_do_not_track_heading_text in
  # style_guide_modal_anchors_test.rb parses the whole file and skips on nil —
  # so it has been asserting nothing. Noted there.) Slicing one section out
  # first gives the parser a small, well-formed chunk with no ERB output tags.
  #
  # The slice runs from the section's opening tag to the first following line
  # that is exactly `  </section>` — subsection closers sit at two-space indent,
  # everything inside them is deeper. Both ends are then VERIFIED, because a
  # slice that silently lands in the wrong place is the failure mode here: a
  # short slice would make the emptiness assertion pass by reading nothing, and
  # an overrun one would drag in the next section's markup.
  def section_dom(id)
    open_tag = %(<section id="#{id}" class="space-y-5">)
    start    = source.index(open_tag)
    refute_nil start, "the #{id} section is missing entirely"

    finish = source.index("\n  </section>", start)
    refute_nil finish, "the #{id} section is never closed at subsection indent"

    slice = source[start..finish]

    assert_equal 1, slice.scan("<section ").length,
                 "the #{id} slice contains #{slice.scan('<section ').length} section tags, so " \
                 "it overran into a sibling and these assertions are reading the wrong markup."

    Nokogiri::HTML.fragment(slice)
  end
end
