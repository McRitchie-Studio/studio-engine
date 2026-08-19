# frozen_string_literal: true

require "test_helper"
require "action_view"

# [unit] Montserrat ships FROM THE ENGINE, same-origin, and cannot swap under a reader.
#
# WHAT THIS REPLACED. layouts/studio/_head.html.erb loaded the family as
#
#   <link rel="preconnect" href="https://fonts.googleapis.com">
#   <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
#   <link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@...&display=swap" rel="stylesheet">
#
# and the interesting half is `display=swap`, not the hostname. That stylesheet blocks
# the load event; the font FILES it names do not. So the page went interactive in the
# fallback font and every glyph was re-measured when Montserrat arrived. Root-caused in
# close-board-filter-flake: the board filter chips changed width AFTER the page was
# interactive, a synthesized click's pointerdown and pointerup landed on different
# elements, and the browser fired click on their common ancestor. Three CI reds in one
# day. click_when_settled guards the TEST lane; nothing guarded a real finger.
#
# WHY THIS FILE IS NOT ONE ASSERTION. "The head names no fonts.googleapis.com" is the
# obvious guard and it is worth almost nothing on its own — DELETING the font entirely
# satisfies it, and so does self-hosting the file and leaving `font-display: swap` in
# place, which reproduces the whole defect from our own origin. Each test below is a
# different way to be wrong, and none of them implies the others:
#
#   * the third party creeping back                          (the thing being fixed)
#   * the family vanishing, so the "no Google" guard passes vacuously
#   * a swap window returning, which is the DEFECT, not the CDN
#   * the src pointing at bytes the gem does not actually ship
#   * the precompile entry missing — Sprockets hosts (mcritchie-studio, turf-monster)
#     serve NOTHING without it while propshaft hosts ignore the list, so it breaks
#     exactly half the fleet and looks fine on the other half
#   * the preload losing `crossorigin`, which silently DOUBLES the download
#   * the 100-900 range outliving the variable file that makes it true
class VendoredMontserratTest < Minitest::Test
  ROOT     = File.expand_path("../..", __dir__)
  HEAD     = File.join(ROOT, "app/views/layouts/studio/_head.html.erb")
  ENGINE   = File.join(ROOT, "lib/studio/engine.rb")
  FONT_DIR = File.join(ROOT, "app/assets/fonts/studio")
  TAILWIND = File.join(ROOT, "tailwind/studio.tailwind.config.js")

  SUBSETS = %w[latin latin-ext].freeze

  def engine = @engine ||= File.read(ENGINE)

  # The head as the BROWSER receives it. Every assertion here is about delivered
  # bytes, and the ERB comment above the block deliberately QUOTES the Google tags it
  # replaced — that prose is the most useful part of the change, and a guard that
  # forbade naming what it removed would send the next reader to git history for the
  # reason.
  def rendered_head
    @rendered_head ||= begin
      view = ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ROOT, "app/views")])
      def view.csrf_meta_tags = ""
      def view.csp_meta_tag = ""
      def view.studio_theme_css_tag = ""
      def view.javascript_importmap_tags = ""
      view.render(partial: "layouts/studio/head").to_s
    end
  end

  # Just the @font-face blocks, so a stray mention of a property elsewhere in the head
  # cannot satisfy an assertion that is about the faces.
  def font_faces = rendered_head.scan(/@font-face\s*\{(.*?)\}/m).flatten

  # ---- the third party is gone -------------------------------------------------

  def test_the_head_reaches_no_google_font_host_at_all
    hosts = rendered_head.scan(%r{fonts\.(?:googleapis|gstatic)\.com}).uniq

    assert_empty hosts,
                 "the head still reaches #{hosts.inspect}. Montserrat is vendored into " \
                 "app/assets/fonts/studio and shipped through the asset pipeline, as alpine, " \
                 "canvas_confetti and sortable already are."
  end

  # preconnect is the tell that a third-party fetch is still expected, even if the
  # stylesheet link itself were rewritten.
  def test_the_head_preconnects_to_nobody
    preconnects = rendered_head.scan(/<link[^>]+rel=["']preconnect["'][^>]*>/i)

    assert_empty preconnects,
                 "a preconnect survives: #{preconnects.inspect}. Nothing in the head should be " \
                 "warming a connection to another origin any more."
  end

  # ---- ...and the font is still THERE ------------------------------------------
  #
  # THE VACUITY GUARD. Every assertion above is satisfied by deleting Montserrat, which
  # would "fix" the layout shift by removing the typeface from the product.

  def test_the_head_declares_the_family_it_stopped_downloading
    refute_empty font_faces, "the head declares no @font-face at all — the family was removed, not vendored"

    families = font_faces.filter_map { |face| face[/font-family:\s*['"]?([^;'"]+)/, 1]&.strip }.uniq

    assert_equal ["Montserrat"], families,
                 "the vendored faces declare #{families.inspect}; the design system asks for Montserrat"
  end

  # A face nobody references is dead weight, and the two halves live in different
  # files, so nothing else in the suite would notice them drifting apart.
  def test_the_declared_family_is_the_one_tailwind_resolves_to
    stack = File.read(TAILWIND)[/sans:\s*\[(.*?)\]/m, 1].to_s
    first = stack.split(",").first.to_s.strip.delete("'\"")

    assert_equal "Montserrat", first,
                 "tailwind's sans stack leads with #{first.inspect}, so the @font-face in the head " \
                 "is never the font that renders. Move both or neither."
  end

  # ---- the actual defect: the swap window --------------------------------------

  def test_every_face_is_font_display_optional
    displays = font_faces.map { |face| face[/font-display:\s*([a-z]+)/, 1] }

    refute_includes displays, nil, "a face declares no font-display, so it inherits the browser default (block-like)"
    assert_equal ["optional"], displays.uniq,
                 "font-display is #{displays.uniq.inspect}. This is the whole point of the change: " \
                 "swap, block, fallback and auto all keep a SWAP PERIOD, so a font that arrives late " \
                 "still re-measures every glyph on an interactive page. optional has no swap period — " \
                 "a late font is abandoned for that navigation instead of shifting the layout under a " \
                 "reader's finger. Self-hosting shortens that window; only optional closes it."
  end

  # ---- the bytes are ours, and they exist --------------------------------------

  def test_every_face_is_served_from_our_own_origin
    srcs = font_faces.filter_map { |face| face[/src:\s*url\(['"]?([^'")]+)/, 1] }

    assert_equal SUBSETS.length, srcs.length, "expected one src per subset, got #{srcs.inspect}"
    srcs.each do |src|
      refute_match %r{\A(?:https?:)?//}, src,
                   "#{src} is an absolute URL — the face must resolve through our own asset pipeline"
      assert_match %r{\A/}, src, "#{src} is not a root-relative same-origin path"
    end
  end

  # asset_path resolving is not the same claim as the file being in the gem. A typo
  # renders a perfectly well-formed 404.
  def test_each_face_points_at_a_woff2_the_gem_actually_ships
    SUBSETS.each do |subset|
      path = File.join(FONT_DIR, "montserrat-#{subset}.woff2")

      assert File.exist?(path), "the vendored #{subset} subset is missing at #{path}"
      assert_equal "wOF2", File.binread(path, 4), "#{path} is not a woff2 file"
      assert_operator File.size(path), :>, 10_000, "#{path} is too small to be a Montserrat subset"
      assert_includes rendered_head, "montserrat-#{subset}.woff2", "no face references the #{subset} subset"
    end
  end

  # THE HALF-THE-FLEET TRAP, same as studio/alpine.js. Without these entries Sprockets
  # hosts serve nothing while propshaft hosts are fine, so the omission reads as "works
  # on my app" right up until the other two render in system-ui.
  def test_both_subsets_are_precompiled
    SUBSETS.each do |subset|
      assert_match %r{^\s*studio/montserrat-#{Regexp.escape(subset)}\.woff2\s*$}, engine,
                   "studio/montserrat-#{subset}.woff2 must be in the engine's assets.precompile list, " \
                   "or Sprockets hosts (mcritchie-studio, turf-monster) will not serve it"
    end
  end

  # ---- the trade-offs that were decided, held in place -------------------------

  # unicode-range is what makes shipping latin-ext free for an English page: without
  # it the browser downloads BOTH subsets on every page, and the second is 68KB.
  def test_each_face_carries_its_unicode_range
    ranges = font_faces.map { |face| face[/unicode-range:\s*([^;]+)/, 1] }

    refute_includes ranges, nil,
                    "a face has no unicode-range, so the browser cannot tell the subsets apart and " \
                    "downloads every one of them on every page"
    assert_equal ranges.length, ranges.uniq.length, "two faces claim the same unicode-range"
    assert_match(/U\+0000-00FF/, ranges.join(" "), "no face covers basic latin")
    assert_match(/U\+0100-02BA/, ranges.join(" "), "no face covers latin extended-A, which real roster names need")
  end

  # The preload is what keeps `optional` from falling back on a cold first paint. A
  # font preload WITHOUT crossorigin does not match the CORS-mode request the
  # @font-face makes, so the browser fetches the file twice and the preload buys
  # nothing — a mistake that leaves no visible trace.
  def test_the_latin_subset_is_preloaded_as_a_cors_font
    preload = rendered_head[/<link[^>]+rel=["']preload["'][^>]*>/i]

    refute_nil preload, "nothing is preloaded, so font-display: optional will often fall back on a cold cache"
    assert_includes preload, "montserrat-latin.woff2", "the preload must name the latin subset"
    assert_match(/\bas=["']font["']/, preload, "a preload without as=font is fetched at the wrong priority")
    assert_match(/\bcrossorigin\b/, preload,
                 "a font preload without crossorigin does not match the @font-face request: the file is " \
                 "downloaded TWICE and the preload accomplishes nothing")
  end

  # latin-ext is 68KB. Preloading it would hand every page the cost this change spent
  # a measurement avoiding.
  def test_the_latin_ext_subset_is_not_preloaded
    preloads = rendered_head.scan(/<link[^>]+rel=["']preload["'][^>]*>/i).join(" ")

    refute_includes preloads, "montserrat-latin-ext.woff2",
                    "latin-ext is preloaded. It is 68KB and most pages never render a glyph from it; " \
                    "unicode-range already fetches it on demand for the pages that do."
  end

  # ---- the 100-900 claim has to be TRUE ----------------------------------------
  #
  # Montserrat v31 as Google serves it is a VARIABLE font, which is why one file per
  # subset covers every weight the fleet uses and why asking for fewer weights would
  # not have saved a byte. If someone swaps in a static instance, `font-weight: 100 900`
  # becomes a lie: the browser synthesizes the other weights, which is both ugly and a
  # different set of glyph metrics — the exact class of problem this task is about.
  def test_the_faces_declare_the_whole_weight_axis
    weights = font_faces.map { |face| face[/font-weight:\s*([^;]+)/, 1]&.strip }

    assert_equal ["100 900"], weights.uniq,
                 "faces declare #{weights.uniq.inspect}. The vendored file is variable, so one face per " \
                 "subset should span the axis rather than pinning a single instance."
  end

  def test_each_vendored_file_is_really_a_variable_font
    SUBSETS.each do |subset|
      tables = woff2_table_tags(File.join(FONT_DIR, "montserrat-#{subset}.woff2"))

      assert_includes tables, "fvar",
                      "montserrat-#{subset}.woff2 has no fvar table, so it is a STATIC font and the " \
                      "`font-weight: 100 900` in the head is false — every weight but one would be " \
                      "synthesized by the browser at metrics of its own invention"
    end
  end

  private

  # Minimal WOFF2 table-directory reader. The header is fixed-width and the directory
  # is one flag byte plus base-128 lengths per table, so the tags are readable without
  # decompressing anything or taking on a font-tooling dependency for one assertion.
  KNOWN_TAGS = %w[
    cmap head hhea hmtx maxp name OS/2 post cvt_ fpgm glyf loca prep CFF_ VORG EBDT
    EBLC gasp hdmx kern LTSH PCLT VDMX vhea vmtx BASE GDEF GPOS GSUB EBSC JSTF MATH
    CBDT CBLC COLR CPAL SVG_ sbix acnt avar bdat bloc bsln cvar fdsc feat fmtx fvar
    gvar hsty just lcar mort morx opbd prop trak Zapf Silf Glat Gloc Feat Sill
  ].freeze

  def woff2_table_tags(path)
    bytes = File.binread(path)
    count = bytes[12, 2].unpack1("n")
    offset = 48
    Array.new(count) do
      flag = bytes.getbyte(offset)
      offset += 1
      index = flag & 0x3F
      if index == 0x3F
        tag = bytes[offset, 4]
        offset += 4
      else
        tag = KNOWN_TAGS[index]
      end
      _length, offset = read_base128(bytes, offset)
      _transformed, offset = read_base128(bytes, offset) if %w[glyf loca].include?(tag) && (flag >> 6) != 0
      tag
    end
  end

  def read_base128(bytes, offset)
    value = 0
    5.times do
      byte = bytes.getbyte(offset)
      offset += 1
      value = (value << 7) | (byte & 0x7F)
      return [value, offset] if byte.nobits?(0x80)
    end
    raise "malformed base-128 length in woff2 table directory"
  end
end
