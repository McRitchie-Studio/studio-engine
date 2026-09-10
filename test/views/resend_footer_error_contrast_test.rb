# frozen_string_literal: true

require "test_helper"

# [unit] The auth resend footer's ERROR SENTENCE must clear WCAG AA on the modal
# card, in both themes — measured, not asserted from a class name.
#
# THE DEFECT THIS PINS. The paragraph was `text-red-400`. It sits on the modal
# card, which is `bg-surface`. Measured through Studio::ThemeResolver on
# turf-monster's real palette (primary #4BAF50 — the app whose fork this block
# was ported from, and the one about to render it):
#
#                        dark card #3C3853      light card #ffffff
#   text-danger-ink      4.50  PASS             5.76  PASS
#   text-red-400         3.86  FAIL             2.89  FAIL
#
# That red-400 is Tailwind v4's oklch(70.4% 0.191 22.216), about #FF6467, which
# is what these apps compile; the v3 hex #F87171 gives 4.03 / 2.77 and fails the
# same way. red-400 fails on EVERY light surface the resolver emits (2.31 to
# 2.89) and on the dark modal card. That is the sentence a user reads when a
# sign-in link fails to resend.
#
# THE ENGINE ALREADY DECIDED THIS. lib/studio/theme_resolver.rb states in its own
# comment that no STATIC red clears AA on BOTH themes — it quotes red-400 at
# 2.77 / 4.03 — and derives `--color-danger-ink` to a 4.5:1 target PRECISELY to
# be the text red. `--color-danger` is the brand FILL and is free to be vivid.
# The partial was using the fill where the contract calls for the ink.
#
# WHY THIS MEASURES INSTEAD OF GREPPING, borrowing turf-monster's own
# test/views/error_text_contrast_test.rb: "assert the class is not text-red-400"
# passes the day someone writes text-rose-300. So nothing here reads a class NAME
# as evidence. The colour token on the alert is RESOLVED — theme tokens through
# ThemeResolver's emitted vars, static Tailwind reds through their hexes — and
# the resulting sRGB colour is measured against the card it actually sits on. A
# new light red fails exactly like the old one, whatever it is called.
#
# AND IT CANNOT PASS BY SEEING NOTHING. A colour token this file cannot resolve
# is a FAILURE, never a skip (`test_a_colour_it_cannot_resolve_is_a_failure`),
# and the parse floors are asserted separately — the failure mode for a scanner
# is going quiet, not going red.
class ResendFooterErrorContrastTest < ActiveSupport::TestCase
  AA = 4.5

  # Reads the committed tree, so it locates both files from itself rather than
  # through an app — same idiom as test/views/profile_partial_utility_guard_test.rb.
  PARTIAL = File.expand_path("../../app/views/studio/modals/auth/_resend_footer.html.erb", __dir__)
  CONFIG  = File.expand_path("../../tailwind/studio.tailwind.config.js", __dir__)

  # turf-monster's REAL configured palette: config/initializers/studio.rb sets
  # theme_primary and theme_accent only, so every other role takes the engine
  # default (dark #1A1535 → surface #3C3853; light surface is the literal
  # #ffffff). Not a convenient palette — the one this block ships into.
  TURF = { primary: "#4BAF50", accent: "#8E82FE" }.freeze

  # `text-<x>` utilities that carry no colour. Anything else must RESOLVE.
  NON_COLOUR = %w[
    3xs 2xs xs sm base lg xl 2xl 3xl 4xl 5xl 6xl 7xl
    left center right justify start end
    wrap nowrap balance pretty ellipsis clip
  ].freeze

  # Static Tailwind text colours, so a partial that names one is MEASURED rather
  # than waved through. These are theme-independent by construction — that is the
  # whole defect. Hexes are Tailwind v3's palette; v4, which the apps compile,
  # shifts them slightly (red-400 is about #FF6467, not #F87171). That cannot
  # flip a verdict: against white and #3C3853 no colour of any hue clears AA on
  # both, since it would need luminance <= 0.183 and >= 0.374 at once.
  STATIC_HEX = {
    "red-300"    => "#FCA5A5", "red-400"  => "#F87171", "red-500"  => "#EF4444",
    "red-600"    => "#DC2626", "rose-300" => "#FDA4AF", "rose-400" => "#FB7185",
    "orange-400" => "#FB923C", "amber-400" => "#FBBF24"
  }.freeze

  # ── what the partial actually says ─────────────────────────────────────────

  def source = @source ||= File.read(PARTIAL)

  # Comments are not markup, and this partial's header discusses `text-red-400`
  # at length — a scanner that counted prose would fail on its own explanation.
  def markup(text = source) = text.gsub(/<%#.*?%>/m, "")

  def alert_tags(text = source)
    markup(text).scan(/<[a-zA-Z][^>]*\brole="alert"[^>]*>/m)
  end

  def alert_classes(text = source)
    alert_tags(text).flat_map { |tag| tag[/\bclass="([^"]*)"/, 1].to_s.split }
  end

  def colour_tokens(text = source)
    alert_classes(text).filter_map do |klass|
      next unless klass.start_with?("text-")

      token = klass.delete_prefix("text-")
      next if NON_COLOUR.include?(token)

      token
    end
  end

  # ── how a token becomes a colour ───────────────────────────────────────────

  # The `text-<name>` → CSS-var map is READ from the shared Tailwind config, not
  # restated here: that file is what the class actually compiles from, so a
  # restatement could go stale against the very thing it claims to describe.
  def text_colour_vars
    @text_colour_vars ||=
      File.read(CONFIG)[/textColor:\s*\{(.*?)\n\s*\},/m, 1]
          .to_s
          .scan(/'?([A-Za-z0-9-]+)'?:\s*'var\((--[a-z0-9-]+)\)'/)
          .to_h
  end

  def theme_vars(scheme)
    @theme_vars ||= {}
    @theme_vars[scheme] ||= Studio::ThemeResolver.new(TURF)
                                                 .send(scheme == :dark ? :dark_mode_vars : :light_mode_vars)
  end

  # The modal card. `bg-surface` on every step of the auth modal.
  def modal_card(scheme) = theme_vars(scheme)["--color-surface"]

  # A token that resolves to nothing is a FAILURE. This is the seam where a
  # scanner normally goes quiet and proves nothing.
  def colour_for(token, scheme)
    if (var = text_colour_vars[token])
      theme_vars(scheme)[var] ||
        flunk("`text-#{token}` maps to #{var}, which ThemeResolver emits in no #{scheme} var")
    elsif STATIC_HEX.key?(token)
      STATIC_HEX[token]
    else
      flunk("`text-#{token}` is on the alert paragraph and this guard cannot resolve it to a " \
            "colour, so it cannot measure it. Teach STATIC_HEX its hex, or register the token " \
            "in tailwind/studio.tailwind.config.js under textColor — do NOT widen NON_COLOUR " \
            "unless it genuinely paints nothing.")
    end
  end

  def ratio(token, scheme)
    Studio::ColorScale.contrast_ratio(colour_for(token, scheme), modal_card(scheme))
  end

  # ── the claim ──────────────────────────────────────────────────────────────

  def test_the_error_sentence_clears_aa_on_the_modal_card_in_both_themes
    tokens = colour_tokens

    assert_equal 1, tokens.length,
                 "expected exactly one text colour on the alert paragraph, found " \
                 "#{tokens.inspect} — this guard measures one sentence, so a second colour " \
                 "means it is now looking at the wrong element"

    %i[dark light].each do |scheme|
      measured = ratio(tokens.first, scheme)

      assert_operator measured, :>=, AA,
                      "the resend error sentence is `text-#{tokens.first}` " \
                      "(#{colour_for(tokens.first, scheme)}) on the #{scheme} modal card " \
                      "(#{modal_card(scheme)}) at #{measured.round(2)}:1 — WCAG AA wants " \
                      "#{AA}:1 for small text. No STATIC red clears AA on BOTH themes; " \
                      "`text-danger-ink` is the per-theme ink ThemeResolver derives for " \
                      "exactly this, and `--color-danger` is the brand FILL, not this."
    end
  end

  # ── the guard's own integrity ──────────────────────────────────────────────

  # THE FLOOR. A regex that stops matching — a renamed file, a rewritten
  # paragraph, `role='alert'` in single quotes — makes the assertion above pass
  # over an empty list forever.
  def test_the_guard_reads_the_paragraph_it_claims_to
    assert File.exist?(PARTIAL), "#{PARTIAL} is gone — re-point this guard, do not delete it"
    assert_equal 1, alert_tags.length,
                 "expected exactly one role=alert element in the resend footer, found " \
                 "#{alert_tags.length}"
    assert_operator alert_classes.length, :>=, 3,
                    "parsed only #{alert_classes.inspect} off the alert — the class attribute " \
                    "is not being read"
    assert_operator text_colour_vars.length, :>=, 5,
                    "parsed only #{text_colour_vars.inspect} out of the shared Tailwind config's " \
                    "textColor block — the map this guard resolves through is not being read"
    assert_includes text_colour_vars.keys, "danger-ink",
                    "the config registers no `danger-ink` text colour, so nothing can use the ink"
  end

  # THE CONTROL. The half a passing guard cannot demonstrate about itself: fed
  # the exact line this partial shipped, the measurement must come out BELOW AA.
  def test_the_guard_would_catch_the_static_red_it_replaced
    shipped = %(<p role="alert" x-show="props.resendError" x-cloak ) +
              %(class="text-xs text-red-400 mt-3 text-center" x-text="props.resendError"></p>)

    assert_equal ["red-400"], colour_tokens(shipped)
    assert_operator ratio("red-400", :light), :<, AA, "red-400 now passes on the light modal card"
    assert_operator ratio("red-400", :dark), :<, AA, "red-400 now passes on the dark modal card"
  end

  # A colour it cannot resolve must be a FAILURE, never a silent skip — the way
  # this class of test usually rots.
  def test_a_colour_it_cannot_resolve_is_a_failure
    assert_raises(Minitest::Assertion) { colour_for("chartreuse-400", :light) }
  end

  # And it must not be fooled by prose: the header comment above the paragraph
  # names `text-red-400` on purpose.
  def test_the_guard_ignores_comments
    prose = <<~ERB
      <%# It replaced text-red-400, which measured 2.77 on the light card. %>
      <p role="alert" class="text-xs text-danger-ink mt-3 text-center"></p>
    ERB

    assert_equal ["danger-ink"], colour_tokens(prose)
  end

  # ── acceptance: the spinner matches the host block this one replaces ────────
  #
  # turf-monster's fork paints a currentColor RING with a transparent gap, via
  # its host-only `.cta-spinner`. The engine's canonical `.spinner` expresses
  # that with its own documented custom properties — and the mapping reads
  # backwards, which is the trap: `--spinner-track` colours the WHOLE ring and
  # `--spinner-color` colours only the leading segment, so the pair is track
  # currentColor plus color transparent. The reverse draws a lone quarter-arc.
  # Left unpinned, a later tidy-up drops the style and silently restores the
  # engine's grey default the moment turf deletes its fork.
  def test_the_spinner_is_the_engine_primitive_tuned_to_the_hosts_ring
    spinner = markup[/<span[^>]*\bclass="spinner"[^>]*>/m]

    refute_nil spinner, "the resend footer no longer renders the engine's `.spinner` primitive"
    refute_match(/cta-spinner/, markup,
                 "`cta-spinner` is a HOST utility (turf-monster's application.css) that the " \
                 "engine defines nowhere — it renders an unstyled empty span in every other " \
                 "consumer")
    assert_match(/--spinner-track:\s*currentColor/, spinner,
                 "the ring must be currentColor so it reads on the resend link in any consumer")
    assert_match(/--spinner-color:\s*transparent/, spinner,
                 "the GAP is the leading segment: --spinner-color transparent. Setting it to " \
                 "currentColor instead draws a quarter-arc, not the host's ring.")
  end
end
