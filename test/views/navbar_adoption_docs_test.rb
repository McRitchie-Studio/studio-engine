# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] The navbar primitive's adoption docs must state the REAL cost, in every
# place a forker reads.
#
# TWO FAILURES EARNED THIS FILE, both in a comments-only change where the prose
# IS the deliverable:
#   1. "a fork adopts with two attributes" understated the cost. Correcting it
#      ONCE, in one file, understated it AGAIN — the list named removals but not
#      the hooks the band table keys on, and missed the title's size binding.
#   2. The correction was spliced into the MIDDLE of an existing sentence,
#      orphaning "from the defaults below." onto its own line.
# Neither is visible to any behavioural test, which is why they are pinned here.
class NavbarAdoptionDocsTest < Minitest::Test
  ENGINE_CSS = "app/assets/tailwind/studio_engine/engine.css"
  NAVBAR     = "app/views/layouts/_navbar.html.erb"

  def test_the_opt_in_sentence_is_not_severed
    # The splice symptom, pinned literally: this sentence must remain contiguous.
    # A paragraph inserted between its halves reads as finished text and passes
    # every other check in this repo.
    assert_includes File.read(ENGINE_CSS),
                    "override only the endpoints that differ\n   from the defaults below."
  end

  def test_every_site_stating_the_opt_in_also_states_the_real_cost
    # engine.css carries the full accounting; _navbar carries the caveat because
    # it is the file a forking app actually opens. A site that promises the
    # opt-in without the caveat is how an adoption ships half-done.
    [ENGINE_CSS, NAVBAR].each do |path|
      body = File.read(path)
      next unless body.include?("navCollapse()")

      assert_match(/OPT.?IN|opt IN/i, body,
                   "#{path} offers navCollapse() without saying the opt-in is not the whole job")
      assert_includes body, "nav-logo-link",
                      "#{path} omits the MOBILE-ONLY hook — a desktop check passes without it"
    end
  end

  def test_the_cost_names_the_title_binding
    # The one that matters most and was missed twice: the h1's size swap is
    # DISCRETE, which is the exact reverse lurch the primitive exists to delete.
    # A fork that keeps it reproduces the bug it is adopting to fix.
    assert_match(/DISCRETE/, File.read(ENGINE_CSS))
    assert_match(/DISCRETE/, File.read(NAVBAR))
  end
end
