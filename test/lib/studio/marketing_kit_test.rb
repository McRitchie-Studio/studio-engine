# frozen_string_literal: true

require "test_helper"

# [unit] Studio::MarketingKit: what an app's kit resolves to. Rendering is
# test/integration/marketing_kit_test.rb; the clipboard is the browser lane.
class MarketingKitTest < Minitest::Test
  Kit = Studio::MarketingKit

  # `locate` as a set of files that exist, so no test needs a public/ directory.
  def resolve(declared = nil, files: [], **options)
    Kit.resolve(declared, nil, locate: ->(file) { files.include?(file) ? file : nil }, **options)
  end

  # ---- derived from the theme ---------------------------------------------------

  def test_a_new_app_gets_its_palette_from_the_theme_config
    kit = resolve(theme: { primary: "#8E82FE", dark: "#1A1535" })

    assert_equal [{ name: "Primary", hex: "#8E82FE" }, { name: "Dark", hex: "#1A1535" }], kit[:palette]
  end

  def test_the_real_default_theme_gives_a_palette_with_nothing_configured
    assert_equal Studio.theme_config.size, resolve(theme: Studio.theme_config)[:palette].size
    refute_empty resolve(theme: Studio.theme_config)[:palette]
  end

  def test_a_new_app_gets_its_logos_from_theme_logos_and_the_favicon_is_not_one
    kit = resolve(logos: [{ file: "favicon.png", title: "Favicon" }, { file: "logo.png", title: "Navbar Logo" }],
                  files: %w[favicon.png logo.png])

    assert_equal ["Navbar Logo"], kit[:logos].map { |logo| logo[:title] }
    assert_equal [:light], kit[:logos].first[:tones].map { |tone| tone[:tone] }
    assert_equal "logo.png", kit[:logos].first[:tones].first[:href]
  end

  def test_brand_artwork_comes_first_with_its_two_tones_and_its_other_format
    kit = resolve(artwork: [["Navbar logo", { light: "/brand/nav-light.svg", dark: "/brand/nav-dark.svg" }], ["Footer logo", nil]],
                  logos: [{ file: "/brand/nav-light.svg", title: "Navbar Logo" }, { file: "logo.png", title: "Auth Logo" }],
                  files: %w[/brand/nav-light.svg /brand/nav-dark.svg /brand/nav-dark.png logo.png])

    assert_equal ["Navbar logo", "Auth Logo"], kit[:logos].map { |logo| logo[:title] }
    light, dark = kit[:logos].first[:tones]
    assert_equal "/brand/nav-light.svg", light[:href]
    assert_equal "/brand/nav-dark.png", dark[:href], "the PNG found beside the declared SVG"
  end

  def test_one_file_under_two_titles_is_one_card
    kit = resolve(logos: [{ file: "logo.png", title: "Navbar Logo" }, { file: "logo.png", title: "Auth Logo" }],
                  files: %w[logo.png])

    assert_equal ["Navbar Logo"], kit[:logos].map { |logo| logo[:title] }
  end

  def test_a_tone_in_the_file_name_finds_the_other_tone_and_format_beside_it
    kit = resolve(logos: [{ file: "brand/icon-light.svg", title: "Icon" }],
                  files: %w[brand/icon-light.svg brand/icon-dark.svg brand/icon-dark.png])
    light, dark = kit[:logos].first[:tones]

    assert_equal [:light, "brand/icon-light.svg"], [light[:tone], light[:href]]
    assert_equal [:dark, "brand/icon-dark.png"], [dark[:tone], dark[:href]]
  end

  def test_a_file_named_for_the_dark_tone_alone_is_the_dark_tile
    kit = resolve(logos: [{ file: "mark_dark.svg", title: "Mark" }], files: %w[mark_dark.svg])

    assert_equal [:dark], kit[:logos].first[:tones].map { |tone| tone[:tone] }
  end

  def test_a_bare_string_entry_takes_its_title_from_the_file
    kit = resolve(logos: ["brand/main-logo.png"], files: %w[brand/main-logo.png])

    assert_equal "Main Logo", kit[:logos].first[:title]
  end

  def test_no_theme_logos_and_no_fonts_are_empty_parts_not_errors
    kit = resolve

    assert_equal [], kit[:logos]
    assert_equal [], kit[:palette]
    assert_equal [], kit[:typefaces]
    assert_nil kit[:tagline]
  end

  # ---- declared ----------------------------------------------------------------

  def test_a_declared_key_wins_and_a_missing_one_still_derives
    kit = resolve({ palette: [{ name: "Ink", hex: "#000000" }], tagline: "Hello" }, theme: { primary: "#8E82FE" })

    assert_equal [{ name: "Ink", hex: "#000000" }], kit[:palette]
    assert_equal "Hello", kit[:tagline]

    kit = resolve({ tagline: "Hello" }, theme: { primary: "#8E82FE" })
    assert_equal ["#8E82FE"], kit[:palette].map { |swatch| swatch[:hex] }
  end

  def test_an_empty_list_declares_none
    kit = resolve({ logos: [] }, logos: [{ file: "logo.png", title: "Navbar Logo" }], files: %w[logo.png])

    assert_equal [], kit[:logos]
  end

  def test_a_callable_receives_the_view_and_string_keys_are_fine
    view = Object.new
    seen = nil
    declared = lambda do |given|
      seen = given
      { "tagline" => "Called" }
    end

    assert_equal "Called", Kit.resolve(declared, view, locate: ->(_) {})[:tagline]
    assert_same view, seen
  end

  def test_a_value_of_the_wrong_type_is_refused_at_configuration
    assert_raises(ArgumentError) { Kit.validate!("not a kit") }
    [nil, false, {}, -> {}].each { |ok| Kit.validate!(ok) }
  end

  # ---- files --------------------------------------------------------------------

  LOGO = { title: "Icon", light: { png: "l.png", svg: "l.svg" }, dark: { png: "d.png", svg: "d.svg" } }.freeze

  def test_the_download_is_the_png_when_there_is_one_and_the_labels_are_exact
    light, dark = resolve({ logos: [LOGO] }, files: %w[l.png l.svg d.png d.svg])[:logos].first[:tones]

    assert_equal ["Download Light", "l.png"], [light[:label], light[:href]]
    assert_equal ["Download Dark", "d.png"], [dark[:label], dark[:href]]
  end

  def test_the_download_falls_back_to_the_svg_when_the_png_is_missing
    light, = resolve({ logos: [LOGO] }, files: %w[l.svg])[:logos].first[:tones]

    assert_equal "l.svg", light[:href]
  end

  def test_the_tile_keeps_its_tone_past_a_hosts_exact_src_repaint
    light, = resolve({ logos: [LOGO] }, files: %w[l.png l.svg])[:logos].first[:tones]

    assert_equal "l.svg?kit", light[:src], "the tile shows the SVG, tagged"
    assert_equal "l.png", light[:href], "the download keeps the plain URL"
    assert_equal "https://cdn.test/l.svg", Kit.tile_src("https://cdn.test/l.svg")
    assert_equal "/a.svg?v=1&kit", Kit.tile_src("/a.svg?v=1")
  end

  def test_a_tone_with_no_file_has_no_tile_and_a_logo_with_no_file_has_no_card
    kit = resolve({ logos: [LOGO, { title: "Gone", light: { png: "gone.png" } }] }, files: %w[l.png])

    assert_equal ["Icon"], kit[:logos].map { |logo| logo[:title] }
    assert_equal [:light], kit[:logos].first[:tones].map { |tone| tone[:tone] }
  end

  def test_malformed_rows_are_skipped_and_never_raise
    kit = resolve({ logos: ["a string", 3, nil, { title: "x", light: 7, dark: nil }],
                    palette: ["red", nil, { name: "No hex" }],
                    typefaces: ["Arial", nil, { role: "No family" }] })

    assert_equal [[], [], []], kit.values_at(:logos, :palette, :typefaces)
  end

  def test_only_a_real_hex_is_a_colour
    hexes = %w[#abc #abcd #AABBCC #AABBCCDD].map { |hex| { name: "ok", hex: hex } }
    bad = ["red", "#12", "#GGGGGG", "#fff;background:url(x)", "", nil].map { |hex| { name: "bad", hex: hex } }

    assert_equal %w[#abc #abcd #AABBCC #AABBCCDD], resolve({ palette: hexes + bad })[:palette].map { |swatch| swatch[:hex] }
  end

  def test_a_family_or_weight_css_cannot_read_stays_out_of_the_style
    face = resolve({ typefaces: [{ role: "Body", family: "x;}</style>", weight: "9;", name: "X" }] })[:typefaces].first

    assert_nil face[:family]
    assert_nil face[:weight]
    assert_equal "X", face[:name]
  end

  def test_locate_refuses_what_is_not_a_file_of_this_app
    ["javascript:alert(1)", "data:image/png;base64,AAAA", "//evil.test/a.png", "../secrets.png", "a/../../b.png", "a b.png", "", nil].each do |file|
      assert_nil Kit.locate(file), file.inspect
    end
    assert_equal "https://cdn.test/a.png", Kit.locate("https://cdn.test/a.png")
  end

  def test_locate_answers_nil_when_looking_raises
    assert_nil Kit.locate(Object.new.tap { |o| def o.to_s = raise("no") })
  end
end
