# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# [unit] Config and art rules for Studio.loader (lib/studio/loader.rb): the
# default is Breathe with no per-app setting, a bare style name or a Hash
# normalizes, a signature style refuses to boot without its art file, and the
# art reader takes only the marked layers from a file inside public/.
class LoaderTest < Minitest::Test
  L = Studio::Loader
  FIXTURES = File.expand_path("../fixtures/files/loader", __dir__)

  def test_the_default_is_breathe_with_no_icon_or_art_named
    assert_equal({ style: :breathe, icon: nil, art: nil }, L.normalize(nil))
    assert_equal :breathe, Studio.loader[:style]
  end

  def test_a_bare_style_name_normalizes
    assert_equal :orbit, L.normalize(:orbit)[:style]
    assert_equal :weld_bead, L.style!("weld-bead")
  end

  def test_a_hash_keeps_its_icon_and_art
    config = L.normalize("style" => "sparkle", "icon" => " /brand/icon.svg ", "art" => "/brand/sparkle.svg")

    assert_equal({ style: :sparkle, icon: "/brand/icon.svg", art: "/brand/sparkle.svg" }, config)
  end

  def test_an_unknown_style_or_key_is_refused_at_boot
    assert_raises(L::InvalidConfig) { L.normalize(:spinny) }
    assert_raises(L::InvalidConfig) { L.normalize(style: :breathe, colour: "red") }
    assert_raises(L::InvalidConfig) { L.normalize(style: :breathe, icon: "  ") }
    assert_raises(L::InvalidConfig) { L.normalize(42) }
  end

  def test_a_signature_style_needs_its_art_file
    error = assert_raises(L::InvalidConfig) { L.normalize(:sparkle) }
    assert_match(/data-loader="spark"/, error.message)
    assert_raises(L::InvalidConfig) { L.normalize(:weld_bead) }
  end

  def test_the_generic_and_signature_styles_are_the_picked_six
    assert_equal %i[breathe liquid orbit steel], L::GENERIC_STYLES
    assert_equal %i[weld_bead sparkle], L::ART_STYLES.keys
  end

  def test_the_art_reader_takes_only_the_marked_layers_with_their_group_transform
    with_public("brand/sparkle.svg" => "studio-sparkle.svg") do |root|
      art = L.art("/brand/sparkle.svg", :sparkle, root: root)

      assert_equal "0 0 370.2 300.2", art[:view_box]
      assert_equal 5, art[:layers].size
      assert_equal "translate(0,0)", art[:layers].first[:transform]
      assert_nil L.art("/brand/sparkle.svg", :weld_bead, root: root), "no outline layer, no bead"
    end
  end

  def test_the_art_reader_refuses_a_missing_file_and_a_path_out_of_public
    with_public("brand/bead.svg" => "welding-bead.svg") do |root|
      assert L.art("/brand/bead.svg", :weld_bead, root: root)
      assert_nil L.art("/brand/missing.svg", :weld_bead, root: root)
      assert_nil L.art("/../#{File.basename(root)}/brand/bead.svg/../../../etc/passwd", :weld_bead, root: root)
      assert_nil L.art("https://example.com/bead.svg", :weld_bead, root: root)
    end
  end

  def test_an_art_file_without_a_viewbox_is_no_art
    assert_nil L.parse_art(%(<svg><path data-loader="spark" d="M0 0L1 1Z"/></svg>), "spark")
    assert_nil L.parse_art("not svg", "spark")
  end

  private

  def with_public(files)
    Dir.mktmpdir do |root|
      files.each do |target, fixture|
        FileUtils.mkdir_p(File.join(root, File.dirname(target)))
        FileUtils.cp(File.join(FIXTURES, fixture), File.join(root, target))
      end
      yield root
    end
  end
end
