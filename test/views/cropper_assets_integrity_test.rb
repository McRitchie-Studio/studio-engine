# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# [unit] studio/_cropper_assets loads Cropper.js 1.6.2 from the engine's own
# assets, never a CDN. It was two cdnjs tags until engine-vendors-cropper-assets,
# and a cdnjs connection that never answered held the load event of every page
# that renders the partial (turf-monster's /account). Each tag keeps its pinned
# sha384 Subresource Integrity and crossorigin="anonymous" (without CORS mode
# the browser cannot check the hash, and the tag fails closed).
#
# test/integration/cropper_assets_sri_test.rb ties the pins to the vendored
# bytes offline, and bin/cropper-sri-live ties those bytes to the npm package
# and to cdnjs.
class CropperAssetsIntegrityTest < Minitest::Test
  CSS_ASSET = "studio/cropper-1.6.2.min.css"
  JS_ASSET = "studio/cropper-1.6.2.min.js"
  CSS_SRI = "sha384-6LFfkTKLRlzFtgx8xsWyBdKGpcMMQTkv+dB7rAbugeJAu1Ym2q1Aji1cjHBG12Xh"
  JS_SRI = "sha384-jrOgQzBlDeUNdmQn3rUt/PZD+pdcRBdWd/HWRqRo+n2OR2QtGyjSaJC0GiCeH+ir"

  def test_the_stylesheet_is_the_vendored_file_pinned
    link = doc.at_css(%(link[rel="stylesheet"][href="/#{CSS_ASSET}"]))

    refute_nil link, "the cropper stylesheet must load from the engine's #{CSS_ASSET}"
    assert_equal CSS_SRI, link["integrity"]
    assert_equal "anonymous", link["crossorigin"]
  end

  def test_the_script_is_the_vendored_file_pinned
    script = doc.at_css(%(script[src="/#{JS_ASSET}"]))

    refute_nil script, "the cropper script must load from the engine's #{JS_ASSET}"
    assert_equal JS_SRI, script["integrity"]
    assert_equal "anonymous", script["crossorigin"]
    assert script.key?("defer"), "the script stays deferred"
  end

  # The defect was a third-party host on the page's load path. None may return.
  def test_nothing_loads_from_another_host
    tags = doc.css("link[href], script[src]")

    assert_equal 2, tags.size
    tags.each do |node|
      url = node["href"] || node["src"]
      refute_match %r{\A(https?:)?//}, url, "#{node.name} loads from another host: #{url}"
      assert_match(/\Asha384-[A-Za-z0-9+\/]{64}\z/, node["integrity"].to_s, "#{node.name} lost its integrity")
    end
  end

  def test_both_files_ship_in_the_gem_and_are_precompiled
    root = File.expand_path("../..", __dir__)
    engine = File.read(File.join(root, "lib/studio/engine.rb"))
    { JS_ASSET => "javascripts", CSS_ASSET => "stylesheets" }.each do |asset, dir|
      body = File.read(File.join(root, "app/assets", dir, asset))
      assert_includes body, "Cropper.js v1.6.2", "#{asset} is not the 1.6.2 build"
      assert_includes body, "Released under the MIT license", "the licence notice must travel with #{asset}"
      assert_match(/^\s*#{Regexp.escape(asset)}\s*$/, engine,
                   "#{asset} must be in the engine's assets.precompile list, or a Sprockets host will not serve it")
    end
  end

  private

  def doc
    @doc ||= begin
      view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
      Nokogiri::HTML::DocumentFragment.parse(view.render(partial: "studio/cropper_assets"))
    end
  end
end
