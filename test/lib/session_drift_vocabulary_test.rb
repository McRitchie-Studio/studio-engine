# frozen_string_literal: true

require "test_helper"

# [unit] The session-drift primitive stays web2 (activity-9423, Mr. McRitchie's
# approved design, 2026-09-16): NOTHING in it may speak wallet, signer, Solana or
# chain vocabulary. The engine owns the generic session primitive; a web3 layer
# (solana-studio's browser JS, turf-monster's server hook) plugs ONE identity
# source into it from outside.
#
# This reads every CODE file the primitive ships and refuses the vocabulary with
# no allowlist. docs/SESSION_DRIFT.md is deliberately NOT scanned: it has to name
# the web3 layer to explain where that layer plugs in.
#
# SessionContext itself is not scanned either, and that is a recorded exception,
# not an oversight: its legacy mode half (mode, phantom_linked?, address) predates
# this primitive and turf-monster hydrates from it, so removing it would break a
# consumer. The new half of that file is asserted vocabulary-free below by reading
# only the methods it added.
class SessionDriftVocabularyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  FORBIDDEN = /wallet|signer|solana|phantom|web3|onchain|on-chain|blockchain|\bchain\b/i

  PRIMITIVE_FILES = %w[
    lib/studio/session_fingerprint.rb
    app/controllers/concerns/studio/session_drift.rb
    app/controllers/studio/session_states_controller.rb
    app/views/studio/_session_stamp.html.erb
    app/assets/javascripts/studio/session.js
    test/support/session_store_harness.js
  ].freeze

  def test_every_primitive_file_exists
    PRIMITIVE_FILES.each do |path|
      assert File.file?(File.join(ROOT, path)), "#{path} is missing, so this guard would scan nothing"
    end
  end

  def test_no_primitive_file_speaks_web3
    offenders = PRIMITIVE_FILES.flat_map do |path|
      File.readlines(File.join(ROOT, path)).each_with_index.filter_map do |line, index|
        "#{path}:#{index + 1}: #{line.strip}" if line.match?(FORBIDDEN)
      end
    end
    assert_empty offenders, "web3 vocabulary in the session-drift primitive:\n#{offenders.join("\n")}"
  end

  def test_the_session_state_half_of_session_context_speaks_no_web3
    source = File.read(File.join(ROOT, "app/models/session_context.rb"))
    half = source[/# ---- Half 1: session state -+\n(.*?)# ---- Half 2: legacy mode/m, 1]
    refute_nil half, "the Half 1 / Half 2 markers moved; this guard would read nothing"
    assert_match(/def to_stamp/, half, "the slice holds the stamp builder")
    offenders = half.lines.grep(FORBIDDEN)
    assert_empty offenders, "web3 vocabulary in SessionContext's session-state half:\n#{offenders.join}"
  end

  def test_the_guard_bites
    assert_match FORBIDDEN, "registerIdentitySource({ name: 'wallet' })"
    assert_match FORBIDDEN, "the Solana signer"
    assert_match FORBIDDEN, "on-chain"
    refute_match FORBIDDEN, "cross-tab session channel sync", "chain must match as a word, not inside channel"
  end
end
