require "test_helper"

# [unit] Responsive Tailwind variants in the partials every consumer renders.
#
# THE BLIND SPOT THIS COVERS, stated plainly: the engine ships a PREBUILT css
# bundle, so a Tailwind utility exists in a consuming app only if that app's own
# views already emitted it. An engine partial can therefore use a class that is
# real here and absent everywhere it actually ships — and NOTHING notices. Not a
# render test, which sees the string either way. Not the browser lane, which is
# worse than silent: e2e/tailwind_input.css carries `@source "../app/views"`, so
# the lane compiles the ENGINE's views and emits utilities no consumer has,
# turning green into evidence for a page that is broken in all five apps.
#
# IT HAS HAPPENED TWICE.
#
#   grid-cols-7 — the birthday calendar's day grid. Present in zero consumer
#                 bundles, so the seven weekday letters stacked into one vertical
#                 column and the popover grew to the height of the page. Every
#                 spec passed the whole time.
#   sm:block    — very nearly. The save controls' change count was written as
#                 `hidden sm:block`, which would have hidden it at EVERY width in
#                 every app. Caught by MEASURING the three consumer bundles
#                 before committing, not by any test — which is why this file
#                 exists.
#
# WHY RESPONSIVE VARIANTS SPECIFICALLY. They are the sharpest case: `hidden` is
# in every bundle and `sm:block` is in none, so the pair reads as obviously fine
# and fails completely. A base utility that is missing usually looks wrong
# immediately; a missing variant looks like a working page at one width.
#
# WHY THIS PARTIAL SET. These are what all five consumers render. The engine's
# own admin pages (style/, error_logs/, schema/, board/) are rendered by
# mcritchie-studio and use variants its bundle has — a rule over those would be
# asserting something this file cannot check.
#
# THE ALLOWLIST IS EVIDENCE, NOT PREFERENCE. Each entry was measured against the
# compiled bundles of mcritchie-studio, mcritchie-industries and turf-monster on
# the date named. To add one, measure it the same way and say so — the whole
# value here is that nothing lands on this list by assumption.
class ProfilePartialUtilityGuardTest < ActiveSupport::TestCase
  # Same idiom as test/lib/e2e_lane_contract_test.rb: this reads the committed
  # tree, so it locates it from this file rather than through the app.
  PARTIAL_DIR = File.expand_path("../../app/views/studio/profiles", __dir__)

  # Verified present in mcritchie-studio, mcritchie-industries AND turf-monster's
  # compiled bundles, 2026-08-15. _name_fields has shipped it since the standard
  # profile columns landed, which is the other half of the evidence.
  PROVEN = ["sm:grid-cols-2"].freeze

  VARIANT = /(?<![\w:-])((?:sm|md|lg|xl|2xl):[A-Za-z0-9\[\]\-.\/%!]+)/

  # Only what actually reaches the browser as a class. Prose is not markup, and
  # this file's own subject matter guarantees the word appears in comments —
  # including in the comment above.
  def classes_in(source)
    without_erb_comments = source.gsub(/<%#.*?%>/m, "")
    without_css_comments = without_erb_comments.gsub(/\/\*.*?\*\//m, "")
    without_css_comments.scan(/\bclass\s*=\s*"([^"]*)"/m).flatten.join(" ")
  end

  def test_shared_profile_partials_use_only_proven_responsive_variants
    offenders = {}

    Dir.glob(File.join(PARTIAL_DIR, "*.erb")).sort.each do |path|
      found = classes_in(File.read(path)).scan(VARIANT).flatten.uniq - PROVEN
      offenders[File.basename(path)] = found if found.any?
    end

    assert_empty offenders,
                 "these responsive variants are used in partials every consumer renders, and " \
                 "are not on the measured allowlist: #{offenders.inspect}. The engine ships a " \
                 "PREBUILT bundle — a variant a consumer's own views never emitted does not " \
                 "exist there, and the page silently renders at one width forever. Either use " \
                 "owned CSS in the partial (see .studio-save-controls in _identity_styles), or " \
                 "measure the variant in all three consumer bundles and add it to PROVEN with " \
                 "the date."
  end

  # THE GUARD MUST ACTUALLY LOOK AT SOMETHING. A glob that matches nothing — a
  # renamed directory, a moved partial set — makes the assertion above pass
  # forever while covering an empty list.
  def test_the_guard_reads_the_partials_it_claims_to
    files = Dir.glob(File.join(PARTIAL_DIR, "*.erb"))

    assert_operator files.length, :>=, 10,
                    "only #{files.length} partial(s) under #{PARTIAL_DIR} — this guard is " \
                    "covering nothing"
    assert_includes files.map { |f| File.basename(f) }, "_save_controls.html.erb"
  end

  # And it must be able to SEE a violation, which is the half a passing guard
  # cannot demonstrate about itself. Feeds the scanner the exact string that was
  # nearly shipped.
  def test_the_guard_would_catch_the_class_that_was_nearly_shipped
    nearly = %(<p class="hidden sm:block text-sm">1 unsaved change</p>)

    assert_equal ["sm:block"], classes_in(nearly).scan(VARIANT).flatten - PROVEN
  end

  # And must NOT be fooled by prose. This file and the partials it guards both
  # discuss `sm:block` at length; a scanner that counted comments would fail on
  # its own explanation.
  def test_the_guard_ignores_comments
    prose = <<~ERB
      <%# OWNED CSS, NOT `hidden sm:block` — see the note. %>
      <style>/* not `hidden sm:block` either */</style>
      <p class="sr-only text-sm">1 unsaved change</p>
    ERB

    assert_empty classes_in(prose).scan(VARIANT).flatten
  end
end
