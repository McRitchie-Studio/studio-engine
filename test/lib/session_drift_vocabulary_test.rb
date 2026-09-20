# frozen_string_literal: true

require "test_helper"
require "tempfile"

# [unit] The session-drift primitive stays generic, in every file it ships.
#
# THE RULE. Mr. McRitchie's decision (task graduate-session-switch-primitive,
# activity-9396, carried by the approved design in activity-9423): nothing of a
# particular external-identity technology enters studio-engine. The engine owns a
# generic session primitive; an app or companion gem plugs its own identity source
# in from outside. The rule is absolute: it covers code, docs, tests and the
# changelog, and this guard grants NO exemption to any of them.
#
# WHAT IS SCANNED.
#   * WHOLE FILES — every file this primitive added: its code, its doc, its tests,
#     its harness, its browser spec, its lab files, and THIS FILE.
#   * OWNED SECTIONS — the passages this primitive added to files it shares with the
#     rest of the engine (the changelog entry, the contract rows, the delegator
#     block in SessionContext, the route and accessor, the head render, the lab
#     action, the lane contract lines). Each is located by its own opening and
#     closing text and scanned whole. A shared file is not scanned end to end
#     because its OTHER passages predate this primitive and document code the
#     engine already runs; rewriting them would hide that code, not remove it.
#
# WHY THE WORD LIST IS SPELLED BACKWARDS. So that this file can scan itself. A
# guard holding the literal words would have to exempt its own file, and the rule
# allows no exemption. Reversing them keeps every word out of this source while
# the regexp still matches the real spellings.
#
# PROVEN TO BITE. test_a_forbidden_word_is_caught_in_a_whole_file and
# test_a_forbidden_word_is_caught_in_an_owned_section run the same scanner over a
# file seeded with each word, so a scanner that stopped reading would redden here
# rather than pass every real file for free.
class SessionDriftVocabularyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  REVERSED = %w[tellaw rengis analos motnahp 3bew niahcno niahc-no niahckcolb yekbup tropmal 85esab].freeze
  WORDS = REVERSED.map(&:reverse).freeze
  # A whole word only, so "channel" and "chains of thought" are not the word itself.
  STANDALONE = "niahc".reverse

  FORBIDDEN = Regexp.new(
    (WORDS.map { |word| Regexp.escape(word) } + ["\\b#{STANDALONE}\\b"]).join("|"),
    Regexp::IGNORECASE
  )

  WHOLE_FILES = %w[
    lib/studio/session_state.rb
    lib/studio/session_fingerprint.rb
    app/controllers/concerns/studio/session_drift.rb
    app/controllers/studio/session_states_controller.rb
    app/views/studio/_session_stamp.html.erb
    app/assets/javascripts/studio/session.js
    docs/SESSION_DRIFT.md
    test/lib/session_drift_vocabulary_test.rb
    test/lib/studio/session_state_test.rb
    test/lib/studio/session_context_test.rb
    test/lib/studio/session_fingerprint_test.rb
    test/integration/session_drift_test.rb
    test/views/studio_session_store_test.rb
    test/support/session_store_harness.js
    e2e/session_drift.spec.js
    test/dummy/app/controllers/session_lab_controller.rb
    test/dummy/app/views/e2e_lab/session_drift.html.erb
  ].freeze

  # [file, opening text, closing text, text the section must contain]
  OWNED_SECTIONS = [
    ["CHANGELOG.md", "- **Session drift: every page now knows", "`#regenerate_session_token!`.", "Studio::SessionState"],
    ["docs/USER_CONTRACT.md", "| `#session_token`", "| `#regenerate_session_token!`", "Studio::SessionFingerprint"],
    ["app/models/session_context.rb", "# ---- Session state (docs/SESSION_DRIFT.md)", "# ---- end session state", "def to_stamp"],
    ["app/controllers/concerns/studio/error_handling.rb", "# The session-drift stamp every page carries", "include Studio::SessionDrift", "SESSION_DRIFT.md"],
    ["app/views/layouts/studio/_head.html.erb", "<%# The session-drift stamp + browser store.", %(<%= render "studio/session_stamp" %>), "ErrorHandling"],
    ["lib/studio.rb", "# Draw the session-drift rehydrate endpoint", "mattr_accessor :session_fingerprint_secret, default: nil", "draw_session_routes"],
    ["lib/studio.rb", "# The session-drift rehydrate endpoint (Studio::SessionStatesController).", "defaults: { format: :json }", "session/state"],
    ["README.md", "- **Session drift**:", "See [`docs/SESSION_DRIFT.md`](docs/SESSION_DRIFT.md).", "StudioSession"],
    ["README.md", "Set `Studio.draw_session_routes = true`", "([`docs/SESSION_DRIFT.md`](docs/SESSION_DRIFT.md)).", "session/state"],
    ["docs/E2E_LANE.md", "## Session drift: what a stub bus cannot vouch for", "not here.", "session_drift.spec.js"],
    # CLOSED ON THE BLOCK'S OWN FROZEN LAST LINE, not on the scalar beneath it. The
    # scalars are DESIGNED to move — every spec added to the lane rewrites them — so a
    # closing marker spelling one out ("total_specs: 140") turns an unrelated spec into
    # a RuntimeError here, naming neither the lane nor session drift. Measured
    # 2026-09-19, when the sidebar-panel close specs took the lane to 142. The lines
    # below are each block's own historical record of what the lister said at the time,
    # so they never change, and `section` takes the FIRST close after the opening — this
    # block's own.
    ["config/e2e_lane.yml", "# 2026-09-16: 138 -> 140", "-> 140 tests in 21 files", "session_drift.spec.js"],
    ["config/e2e_lane.yml", "# Re-derived once more on THIS tree with the lister when the session-drift specs", "# total_specs and the equality assertion holds.", "140 tests"],
    ["test/test_helper.rb", "# Mirrors the session-drift accessors", "mattr_accessor :session_fingerprint_secret, default: nil", "draw_session_routes"],
    ["test/dummy/config/routes.rb", "# Opt in to the session-drift rehydrate endpoint", "Studio.draw_session_routes = true", "session/state"],
    ["test/dummy/config/routes.rb", "# A host app's ordinary page + sign-in/out", %(post "lab/session/sign_out"), "session_lab"],
    ["test/dummy/app/controllers/e2e_lab_controller.rb", "# The session-drift page (e2e/session_drift.spec.js).", "render(:session_drift)", "def session_drift"]
  ].freeze

  # ---- the scanner ------------------------------------------------------------

  def offending_lines(text, label)
    text.lines.each_with_index.filter_map do |line, index|
      "#{label}:#{index + 1}: #{line.strip}" if line.match?(FORBIDDEN)
    end
  end

  # The section from the line holding `opening` through the end of the line holding
  # the first `closing` after it. Raises when either is missing or `opening` is not
  # unique, so a moved marker reddens instead of scanning nothing.
  def section(text, opening, closing)
    first = text.index(opening)
    raise "opening text not found: #{opening.inspect}" if first.nil?
    raise "opening text is not unique: #{opening.inspect}" if text.index(opening, first + 1)

    start = text.rindex("\n", first).to_i
    finish = text.index(closing, first)
    raise "closing text not found after the opening: #{closing.inspect}" if finish.nil?

    line_end = text.index("\n", finish) || text.length
    text[start...line_end]
  end

  def read(path) = File.read(File.join(ROOT, path))

  # ---- the rule, applied ------------------------------------------------------

  def test_every_whole_file_exists
    WHOLE_FILES.each do |path|
      assert File.file?(File.join(ROOT, path)), "#{path} is missing, so this guard would scan nothing"
    end
  end

  def test_the_guard_scans_itself
    assert_includes WHOLE_FILES, "test/lib/session_drift_vocabulary_test.rb"
    assert_empty offending_lines(File.read(__FILE__), File.basename(__FILE__)),
                 "this file holds none of the words, reversed list included"
  end

  def test_every_owned_section_is_found_and_holds_what_it_should
    OWNED_SECTIONS.each do |path, opening, closing, anchor|
      slice = section(read(path), opening, closing)
      assert_includes slice, anchor, "#{path}: the section #{opening.inspect} no longer holds #{anchor.inspect}"
    end
  end

  def test_no_whole_file_names_a_forbidden_word
    offenders = WHOLE_FILES.flat_map { |path| offending_lines(read(path), path) }
    assert_empty offenders, "forbidden vocabulary in a session-drift file:\n#{offenders.join("\n")}"
  end

  def test_no_owned_section_names_a_forbidden_word
    offenders = OWNED_SECTIONS.flat_map do |path, opening, closing, _anchor|
      offending_lines(section(read(path), opening, closing), "#{path} (#{opening[0, 40]}...)")
    end
    assert_empty offenders, "forbidden vocabulary in a session-drift section:\n#{offenders.join("\n")}"
  end

  # ---- the guard bites ---------------------------------------------------------

  def test_the_word_list_is_complete
    assert_equal 11, WORDS.size
    assert_equal WORDS.size, WORDS.uniq.size
  end

  def test_a_forbidden_word_is_caught_in_a_whole_file
    (WORDS + [STANDALONE]).each do |word|
      Tempfile.create(["vocabulary_control", ".md"]) do |file|
        file.write("A clean line.\nAnother clean line about #{word.capitalize} here.\n")
        file.flush
        offenders = offending_lines(File.read(file.path), "control")
        assert_equal ["control:2: Another clean line about #{word.capitalize} here."], offenders,
                     "the scanner missed #{word.inspect}"
      end
    end
  end

  def test_a_forbidden_word_is_caught_in_an_owned_section_and_only_there
    word = WORDS.first
    text = "before #{word}\n- **Opening** marker\nmiddle #{word}\nclosing marker.\nafter #{word}\n"
    slice = section(text, "- **Opening**", "closing marker.")

    assert_equal 1, offending_lines(slice, "control").size, "the word inside the section is caught"
    refute_includes slice, "before", "text before the opening is not part of the section"
    refute_includes slice, "after", "text after the closing is not part of the section"
  end

  def test_a_missing_marker_reddens_rather_than_scanning_nothing
    assert_raises(RuntimeError) { section("nothing here", "- **Opening**", "closing") }
    assert_raises(RuntimeError) { section("- **Opening** once\n- **Opening** twice\nclosing", "- **Opening**", "closing") }
    assert_raises(RuntimeError) { section("- **Opening** with no end", "- **Opening**", "closing") }
  end

  def test_the_standalone_word_is_matched_only_as_a_word
    refute_match FORBIDDEN, "cross-tab channel sync"
    assert_match FORBIDDEN, "a #{STANDALONE} of blocks"
  end
end
