# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/studio/knowledge_transcript"

# [unit] Studio::KnowledgeTranscript: transcript text to (seconds, speaker,
# text) cues. Both layouts the layer holds, both stamp forms, what is NOT a
# cue, and every bound. All names and lines here are invented.
class StudioKnowledgeTranscriptTest < Minitest::Test
  KT = Studio::KnowledgeTranscript

  LAYOUT_A = <<~TEXT
    Weekly Standup
    VIEW RECORDING - 31 mins: https://notes.example.com/share/abc123
    ---

    0:02 - Jordan Example (Example Co)
      Good morning, everyone.
      Shall we start?

    0:15 - Riley Sample (Sample LLC)
      Yes, go ahead.

    1:02:03 - Jordan Example (Example Co)
      That is the hour mark.
  TEXT

  LAYOUT_B = <<~TEXT
    Weekly Standup

    Jordan Example • 0:02
    Good morning, everyone.
    Shall we start?

    Riley Sample • 12:40
    Yes, go ahead.

    Jordan Example • 1:02:03
    That is the hour mark.
  TEXT

  def triples(text) = KT.parse(text).map(&:to_a)

  def test_layout_a_reads_stamp_speaker_and_the_indented_text
    assert_equal [
      [2, "Jordan Example (Example Co)", "Good morning, everyone.\nShall we start?"],
      [15, "Riley Sample (Sample LLC)", "Yes, go ahead."],
      [3723, "Jordan Example (Example Co)", "That is the hour mark."]
    ], triples(LAYOUT_A)
  end

  def test_layout_b_reads_speaker_stamp_and_the_following_lines
    assert_equal [
      [2, "Jordan Example", "Good morning, everyone.\nShall we start?"],
      [760, "Riley Sample", "Yes, go ahead."],
      [3723, "Jordan Example", "That is the hour mark."]
    ], triples(LAYOUT_B)
  end

  def test_header_lines_before_the_first_cue_are_not_cues
    cues = KT.parse(LAYOUT_A)
    refute(cues.any? { |cue| cue.text.include?("VIEW RECORDING") || cue.text.include?("Weekly Standup") })
    refute(cues.any? { |cue| cue.text.include?("---") })
  end

  def test_crlf_line_endings_read_the_same
    assert_equal triples(LAYOUT_A), triples(LAYOUT_A.gsub("\n", "\r\n"))
    assert_equal triples(LAYOUT_B), triples(LAYOUT_B.gsub("\n", "\r\n"))
  end

  def test_the_two_layouts_may_be_mixed
    text = "0:01 - Jordan Example\n  One.\nRiley Sample • 0:05\nTwo.\n"
    assert_equal [[1, "Jordan Example", "One."], [5, "Riley Sample", "Two."]], triples(text)
  end

  def test_stamps
    assert_equal 2, KT.seconds_of("0:02")
    assert_equal 599, KT.seconds_of("9:59")
    assert_equal 4502, KT.seconds_of("75:02"), "minutes may pass 59 when there is no hour"
    assert_equal 3723, KT.seconds_of("1:02:03")
    assert_equal 36_000, KT.seconds_of("10:00:00")
    ["0:60", "1:60:00", "1:00:60", "0:2", "02", ":02", "0:02:", "a:02", "1:2:3:4", "", "0:002",
     "1234:00", "٠:٠٢", "0:02\n", "999:59:590"].each do |token|
      assert_nil KT.seconds_of(token), "#{token.inspect} is not a stamp"
    end
  end

  def test_an_indented_stamp_line_is_speech_not_a_cue
    text = "0:02 - Jordan Example\n  We said\n  10:30 - that is when we agreed to meet\n"
    assert_equal [[2, "Jordan Example", "We said\n10:30 - that is when we agreed to meet"]], triples(text)
  end

  def test_a_bullet_in_a_name_is_kept_and_the_last_bullet_splits
    assert_equal [[5, "Jordan • Example", "Hi."]], triples("Jordan • Example • 0:05\nHi.\n")
  end

  def test_lines_that_only_look_like_cues_are_not
    ["0:02 Jordan Example\n", "0:02 -Jordan\n", "0:02 - \n", "• 0:02\n", "Jordan • later\n",
     "Jordan • 0:60\n", "0:61 - Jordan\n"].each do |line|
      assert_empty KT.parse(line), "#{line.inspect} opens no cue"
    end
  end

  def test_en_and_em_dashes_are_read_in_layout_a
    assert_equal [[2, "Jordan Example", ""], [3, "Riley Sample", ""]],
                 triples("0:02 – Jordan Example\n0:03 — Riley Sample\n")
  end

  def test_text_that_is_not_a_transcript_answers_no_cues
    ["", "   \n\n", "Dear Jordan,\n\nThe meeting is at 10:30 - see you there.\n", "{\"a\": [1, 2]}",
     "name,amount\nwidget,12:30\n", "%PDF-1.7\n\x00\x01\x02 binary"].each do |text|
      assert_empty KT.parse(text)
      refute KT.read(text).truncated?
    end
  end

  def test_nothing_raises_whatever_is_handed_in
    [nil, 42, :sym, [], {}, Object.new].each { |value| assert_empty KT.parse(value) }

    random = Random.new(20_261_008)
    50.times do
      bytes = random.bytes(random.rand(0..4096))
      assert_kind_of Array, KT.parse(bytes)
      assert_kind_of Array, KT.parse(bytes.dup.force_encoding(Encoding::UTF_8))
    end
    assert_equal [[2, "Jordan Example", "Hi."]], triples("0:02 - Jordan Example\n  Hi.\n".encode(Encoding::UTF_16LE))
    assert_equal [[2, "Jordan Example", "Hi."]], triples("0:02 - Jordan Example\n  Hi.\n".b)
    assert_kind_of Array, KT.parse("0:02 - Jor\xFFdan\n  H\xC3i\n".b)
    assert_kind_of Array, KT.parse("abc".dup.force_encoding(Encoding::UTF_7))
  end

  def test_invalid_bytes_become_the_replacement_character
    cue = KT.parse("0:02 - Jordan\n  caf\xFF\n".b).first
    assert_equal "caf�", cue.text
    assert cue.text.valid_encoding?
  end

  def test_the_result_is_frozen
    cues = KT.parse(LAYOUT_A)
    assert cues.frozen?
    assert cues.first.text.frozen?
  end

  # ─── the bounds ─────────────────────────────────────────────────────────────

  def test_text_past_the_byte_cap_is_ignored_and_flagged
    early = "0:02 - Jordan Example\n  Hello there.\n"
    late = "9:59 - Riley Sample\n  Past the cap.\n"
    # Lines that open no cue and sit BEFORE the first one, so they are dropped
    # and only the byte cap is in play.
    filler = "===\n" * ((KT::MAX_TEXT_BYTES - early.bytesize - 40) / 4)
    result = KT.read(filler + early + ("=" * 100) + "\n" + late)

    assert_operator (filler + early).bytesize, :<, KT::MAX_TEXT_BYTES
    assert result.truncated?
    assert_equal ["Jordan Example"], result.cues.map(&:speaker), "a cue past MAX_TEXT_BYTES is never read"

    under = KT.read("===\n" * 1000 + early + late)
    refute under.truncated?
    assert_equal ["Jordan Example", "Riley Sample"], under.cues.map(&:speaker)
  end

  def test_cues_stop_at_the_cap_and_say_so
    text = "0:01 - Jordan Example\n" * (KT::MAX_CUES + 25)
    result = KT.read(text)
    assert_equal KT::MAX_CUES, result.cues.size
    assert result.truncated?

    exact = KT.read("0:01 - Jordan Example\n" * KT::MAX_CUES)
    assert_equal KT::MAX_CUES, exact.cues.size
    refute exact.truncated?
  end

  def test_one_cues_text_stops_at_its_cap
    line = "  #{'w' * 1000}\n"
    result = KT.read("0:02 - Jordan Example\n" + line * 20 + "0:09 - Riley Sample\n  Next.\n")
    assert_operator result.cues.first.text.bytesize, :<=, KT::MAX_CUE_TEXT_BYTES
    assert_operator result.cues.first.text.bytesize, :>, KT::MAX_CUE_TEXT_BYTES - 1001
    assert result.truncated?
    assert_equal "Next.", result.cues.last.text, "the next cue still reads"
  end

  def test_a_cut_inside_a_multibyte_character_leaves_valid_text
    result = KT.read("0:02 - Jordan Example\n  #{'é' * KT::MAX_CUE_TEXT_BYTES}\n")
    assert result.cues.first.text.valid_encoding?
    assert_operator result.cues.first.text.bytesize, :<=, KT::MAX_CUE_TEXT_BYTES
  end

  def test_a_long_line_is_never_a_cue_line
    long_speaker = "J" * (KT::MAX_CUE_LINE_BYTES + 1)
    assert_empty KT.parse("0:02 - #{long_speaker}\n")
    assert_empty KT.parse("#{long_speaker} • 0:02\n")
    assert_empty KT.parse("0:02 - #{'J' * (KT::MAX_SPEAKER_CHARS + 1)}\n"), "a 121-character speaker is text"
    assert_equal 1, KT.parse("0:02 - #{'J' * KT::MAX_SPEAKER_CHARS}\n").size
  end

  # A hostile line must cost time in proportion to its length. Each of these is
  # at the 2 MB cap; at quadratic cost any one would run for minutes.
  def test_pathological_input_is_read_in_linear_time
    cap = KT::MAX_TEXT_BYTES
    hostile = {
      "one line of digits and colons" => "1:" * (cap / 2),
      "one line of spaces then a stamp" => "#{' ' * (cap - 8)}• 0:02",
      "one line of bullets" => "•" * (cap / 3),
      "one line of dashes after a stamp" => "0:00 #{'- ' * (cap / 2 - 3)}",
      "short lines of bullets" => "#{'• ' * 200}\n" * (cap / 401),
      "short lines of near-stamps" => "#{'1:2' * 150} - x\n" * (cap / 456),
      "short lines of spaces" => "#{' ' * 500}\n" * (cap / 501),
      "stamp then many spaces" => "0:02#{' ' * 500}- x\n" * (cap / 508)
    }
    hostile.each do |name, text|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      KT.read(text)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 2.0, "#{name}: #{elapsed.round(2)}s for #{text.bytesize} bytes"
    end
  end
end
