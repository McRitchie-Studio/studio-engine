# frozen_string_literal: true

require "test_helper"

# [unit] Studio::Booking's crop (config.booking_crop, `studio_booking_frame
# crop:`) and the booking page's path (config.booking_path): the pure rules.
# The config setters themselves need the engine loaded, so they are in the
# integration file. The booking URLs are
# in site_footer_test.rb beside this file; rendering is
# test/integration/site_footer_test.rb; the layout is the browser lane.
class BookingCropTest < Minitest::Test
  MEASURED = { top: 200, bottom: 600, frame_height: 720 }.freeze

  def setup
    @reporter = Studio::Booking.reporter
    @reports = []
    Studio::Booking.reporter = ->(message) { @reports << message }
    Studio::Booking.reported.clear
  end

  def teardown
    Studio::Booking.reporter = @reporter
    Studio::Booking.reported.clear
  end

  def crop(declared) = Studio::Booking.crop(declared)

  # ---- derivation -------------------------------------------------------------

  def test_no_crop_is_nil_and_says_nothing
    assert_nil crop(nil)
    assert_nil crop(false)
    assert_empty @reports
  end

  def test_the_window_is_the_measured_box_plus_a_margin_on_each_edge
    assert_equal 6, Studio::Booking::CROP_MARGIN
    assert_equal({ offset: 194, window: 412, frame_height: 720 }, crop(MEASURED))
    assert_empty @reports
  end

  def test_the_window_always_contains_the_whole_measured_box
    [MEASURED, { top: 3, bottom: 500, frame_height: 700 }, { top: 150, bottom: 698, frame_height: 700 }].each do |declared|
      resolved = crop(declared)

      assert_operator resolved[:offset], :<=, declared[:top], "#{declared}: the window starts below the box's top"
      assert_operator resolved[:offset] + resolved[:window], :>=, declared[:bottom], "#{declared}: the window ends above the box's bottom"
      assert_operator resolved[:offset], :>=, 0
      assert_operator resolved[:offset] + resolved[:window], :<=, declared[:frame_height]
    end
  end

  def test_the_margin_is_held_inside_the_frame
    assert_equal({ offset: 0, window: 506, frame_height: 700 }, crop(top: 3, bottom: 500, frame_height: 700))
    assert_equal({ offset: 144, window: 556, frame_height: 700 }, crop(top: 150, bottom: 698, frame_height: 700))
  end

  def test_string_keys_and_fractions_are_read
    assert_equal({ offset: 194, window: 412, frame_height: 720 },
                 crop("top" => 200.4, "bottom" => 599.6, "frame_height" => 720.0))
  end

  def test_the_wrapper_carries_the_crop_as_custom_properties
    assert_equal "--booking-crop-offset: 194px; --booking-crop-window: 412px; --booking-frame-height: 720px",
                 Studio::Booking.crop_style(crop(MEASURED))
    assert_nil Studio::Booking.crop_style(nil)
  end

  # ---- clamping ---------------------------------------------------------------

  REFUSED = {
    "top is negative" => { top: -1, bottom: 600, frame_height: 720 },
    "bottom is not below top" => { top: 600, bottom: 200, frame_height: 720 },
    "bottom is not below top (equal)" => { top: 200, bottom: 200, frame_height: 720 },
    "bottom is outside the frame" => { top: 200, bottom: 721, frame_height: 720 },
    "the window is the whole frame" => { top: 4, bottom: 716, frame_height: 720 },
    "frame_height must be a number" => { top: 200, bottom: 600 },
    "top, bottom must be a number" => { top: "200", bottom: nil, frame_height: 720 },
    "bottom must be a number" => { top: 200, bottom: Float::NAN, frame_height: 720 },
    "it is not a Hash" => "200-600"
  }.freeze

  def test_a_value_that_cannot_be_a_crop_shows_the_frame_whole_and_says_why
    REFUSED.each do |why, declared|
      @reports.clear
      Studio::Booking.reported.clear

      assert_nil crop(declared), "#{declared.inspect} must not crop"
      assert_equal 1, @reports.size, "#{declared.inspect} must be reported"
      assert_includes @reports.first, "(#{why.sub(/ \(equal\)\z/, '')})"
      assert_includes @reports.first, "the frame shows whole"
    end
  end

  def test_a_refused_crop_is_reported_once_however_often_it_renders
    3.times { assert_nil crop(top: 600, bottom: 200, frame_height: 720) }
    assert_equal 1, @reports.size

    crop(top: -5, bottom: 200, frame_height: 720)
    assert_equal 2, @reports.size, "a different refused crop is its own report"
  end
end

class BookingPathTest < Minitest::Test
  Drawn = Struct.new(:studio_booking_path, :schedule_path)
  Request = Struct.new(:path)
  Viewer = Struct.new(:signed_in, :controller_name, :controller_path, :request) do
    def logged_in? = signed_in
  end

  def view = Drawn.new("/schedule", "/book")

  def path_for(declared, view = self.view, drawn: false) = Studio::Booking.path_for(declared, view, drawn: drawn)

  def test_with_neither_declared_there_is_no_booking_page
    assert_nil path_for(nil)
    assert_nil path_for(nil, Object.new)
  end

  def test_the_engines_page_is_the_booking_page_when_drawn
    assert_equal "/schedule", path_for(nil, drawn: true)
    assert_nil path_for(nil, Object.new, drawn: true), "a view with no route helper has no engine page"
  end

  def test_a_declared_string_is_the_booking_page_without_the_engines_route
    assert_equal "/book", Studio::Booking.normalize_path(" /book ")
    assert_equal "/book", path_for("/book")
    assert_equal "/book", path_for("/book", Object.new), "a String needs nothing from the view"
  end

  def test_a_callable_receives_the_view
    assert_equal "/book", path_for(->(view) { view.schedule_path })
  end

  def test_the_apps_own_page_wins_over_the_engines
    assert_equal "/book", path_for("/book", drawn: true)
  end

  def test_a_callable_that_declines_falls_back_to_the_engines_page
    declines = ->(_view) { nil }

    assert_nil path_for(declines)
    assert_equal "/schedule", path_for(declines, drawn: true)
  end

  def test_only_nil_a_path_or_a_callable_is_accepted
    callable = ->(_view) { "/book" }
    assert_nil Studio::Booking.normalize_path(nil)
    assert_nil Studio::Booking.normalize_path("  "), "blank is unset"
    assert_same callable, Studio::Booking.normalize_path(callable)

    ["schedule", "https://example.com/schedule", :schedule, 5].each do |bad|
      error = assert_raises(ArgumentError, bad.inspect) { Studio::Booking.normalize_path(bad) }
      assert_match(%r{a path beginning with "/"}, error.message)
    end
  end

  def test_same_path_ignores_a_query_a_fragment_and_a_trailing_slash
    assert Studio::Booking.same_path?("/book", "/book")
    assert Studio::Booking.same_path?("/book/", "/book?from=footer#top")
    assert Studio::Booking.same_path?("/", "/")
    refute Studio::Booking.same_path?("/book/now", "/book")
    refute Studio::Booking.same_path?("/books", "/book")
    refute Studio::Booking.same_path?("", ""), "nothing is not a page"
    refute Studio::Booking.same_path?("/book", nil)
  end

  # The footer-visibility exemption: a signed-in viewer keeps the footer on the
  # app's own booking page, as on the engine's.
  def test_a_signed_in_viewer_keeps_the_footer_on_the_apps_own_booking_page
    on_page = Viewer.new(true, "schedule", "schedule", Request.new("/book"))
    elsewhere = Viewer.new(true, "schedule", "schedule", Request.new("/board"))
    visible = ->(viewer, path) { Studio::SiteFooter.default_visible?(viewer, controllers: [], booking_path: path) }

    refute visible.call(on_page, nil), "CONTROL: with no booking page declared it is a working page"
    assert visible.call(on_page, "/book")
    refute visible.call(elsewhere, "/book"), "the exemption is the booking page alone"
    refute visible.call(Viewer.new(true, "schedule", "schedule", nil), "/book"),
           "a view with no request is not on the booking page"
  end
end
