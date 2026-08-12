# frozen_string_literal: true

require "test_helper"
require "action_view"
require "active_support/time"
# ActionView's TagBuilder reaches for BigDecimal when it serializes a non-String
# attribute value (the epoch). A host app has it loaded long before any view
# renders; this Rails-free harness does not, so require it here rather than
# stringify the epoch to suit the test.
require "bigdecimal"
require_relative "../../app/helpers/studio/at_time_helper"

# The "at" format primitive. These pin the SERVER half — the clock shape, when the
# date joins it, and the markup contract the client half re-stamps through
# (studio/_at_time_script).
#
# The flag is deliberately absent from every assertion here, and that is the
# design under test as much as anything else: the server cannot know the reader's
# timezone, so it must never assert one.
#
# WHERE THE FLAG IS COVERED, STATED EXACTLY. This repo has no browser lane, so
# nothing here can execute the client half. The flag's behavior is covered today
# in mcritchie-studio's Playwright lane (e2e/at_time_flag.spec.js), against ITS
# copy of this script — the two are kept byte-identical by hand until
# /tasks/adopt-at-format-from-gem swaps the hub onto the gem and that spec covers
# this file directly. Until then: no browser proof runs in THIS repo's CI.
class AtTimeHelperTest < Minitest::Test
  # A fixed "now"; every case is positioned against it, so the today/not-today
  # boundary is tested rather than whatever day CI happens to run on.
  NOW = Time.utc(2026, 8, 11, 20, 0, 0)

  def setup
    @previous_zone = Time.zone
    Time.zone = "UTC"
  end

  def teardown
    Time.zone = @previous_zone
  end

  def view
    @view ||= begin
      v = ActionView::Base.with_empty_template_cache.with_view_paths([])
      v.extend(Studio::AtTimeHelper)
      v
    end
  end

  def test_clock_is_twelve_hour_with_a_single_letter_meridiem
    assert_equal "3:53p", view.at_clock(Time.utc(2026, 8, 11, 15, 53, 0))
    assert_equal "11:07a", view.at_clock(Time.utc(2026, 8, 11, 11, 7, 0))
  end

  def test_clock_names_the_meridiem_boundaries_as_twelve_never_zero
    assert_equal "12:00a", view.at_clock(Time.utc(2026, 8, 11, 0, 0, 0))
    assert_equal "12:30p", view.at_clock(Time.utc(2026, 8, 11, 12, 30, 0))
    assert_equal "11:59a", view.at_clock(Time.utc(2026, 8, 11, 11, 59, 0))
  end

  def test_clock_is_nil_safe
    assert_nil view.at_clock(nil)
    assert_nil view.at_clock("")
  end

  def test_date_is_nil_today_and_adds_the_year_only_when_it_differs
    assert_nil view.at_date(NOW - (3 * 3600), now: NOW)
    assert_equal "Aug 10", view.at_date(Time.utc(2026, 8, 10, 15, 53, 0), now: NOW)
    assert_equal "Aug 10 2025", view.at_date(Time.utc(2025, 8, 10, 15, 53, 0), now: NOW)
  end

  def test_date_turns_over_at_the_calendar_boundary_not_at_twenty_four_hours
    # 20 hours before NOW, but yesterday's date — the date is what disambiguates it.
    assert_equal "Aug 10", view.at_date(Time.utc(2026, 8, 10, 23, 59, 0), now: NOW)
  end

  def test_stamp_text_is_the_clock_alone_today_and_date_prefixed_otherwise
    assert_equal "3:53p", view.at_stamp_text(Time.utc(2026, 8, 11, 15, 53, 0), now: NOW)
    assert_equal "Aug 10, 3:53p", view.at_stamp_text(Time.utc(2026, 8, 10, 15, 53, 0), now: NOW)
    assert_nil view.at_stamp_text(nil, now: NOW)
  end

  def test_tag_carries_the_epoch_the_client_re_stamps_from
    time = Time.utc(2026, 8, 11, 15, 53, 0)
    html = view.at_time_tag(time, now: NOW)

    assert_includes html, %(data-at-epoch="#{time.to_i}")
    assert_includes html, %(datetime="#{time.utc.iso8601}")
    assert_includes html, "data-at-stamp"
  end

  def test_tag_prefixes_with_at_by_default_and_honors_an_explicit_prefix
    time = Time.utc(2026, 8, 11, 15, 53, 0)

    assert_includes view.at_time_tag(time, now: NOW), ">at 3:53p</span>"
    assert_includes view.at_time_tag(time, prefix: nil, now: NOW), ">3:53p</span>"
    # The client rebuilds the whole label, so it needs the prefix as data.
    assert_includes view.at_time_tag(time, now: NOW), %(data-at-prefix="at")
  end

  def test_tag_renders_an_empty_hidden_flag_slot_to_the_right
    html = view.at_time_tag(Time.utc(2026, 8, 11, 15, 53, 0), now: NOW)

    # Empty (the server asserts no country), hidden (so it reserves no margin),
    # and ml-2 (the flag sits to the RIGHT of the clock, with space).
    assert_includes html, %(<span class="ml-2" hidden="hidden" data-at-flag=""></span>)
    # The flag slot follows the text slot with NO whitespace between them — the
    # gap is the margin, so it collapses when the slot is hidden.
    assert_match(%r{</span><span class="ml-2" hidden="hidden" data-at-flag=""></span>}, html)
  end

  def test_tag_keeps_the_relative_phrase_in_the_hover_title
    html = view.at_time_tag(Time.current - (7 * 60))

    assert_match(/title="7 minutes ago ·/, html)
  end

  def test_tag_folds_every_spelling_of_no_prefix_to_the_same_thing_on_both_halves
    time = Time.utc(2026, 8, 11, 15, 53, 0)

    [nil, "", false].each do |blank|
      html = view.at_time_tag(time, prefix: blank, now: NOW)

      assert_includes html, ">3:53p</span>", "prefix #{blank.inspect} renders bare"
      # The client REBUILDS the label from this attribute, so a stringified value
      # here hydrates to a visible "false 3:53p" the server never showed.
      refute_includes html, "data-at-prefix",
                      "prefix #{blank.inspect} must omit the attribute, not stringify it"
    end
  end

  def test_tag_measures_the_hover_title_against_the_injected_now
    time = Time.utc(2026, 8, 11, 15, 53, 0) # 4h 7m before NOW

    assert_includes view.at_time_tag(time, now: NOW), 'title="about 4 hours ago ·',
                    "an injected now must reach the title too, or it describes a different " \
                    "moment than the label beside it"
  end

  def test_tag_is_nil_for_a_blank_time_so_callers_need_no_guard
    assert_nil view.at_time_tag(nil)
    assert_nil view.at_time_tag("")
  end
end
