# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# [unit] studio/_cropper_assets loads Cropper.js 1.6.2 from cdnjs. Each remote
# tag must carry its pinned sha384 Subresource Integrity and
# crossorigin="anonymous" (without CORS mode the browser cannot check the hash,
# and the tag fails closed). The URLs stay exact because Turf Monster's CSP
# names the script by file.
#
# The pinned values are sha384 over the files cdnjs serves;
# test/integration/cropper_assets_sri_test.rb recomputes them offline from
# byte-exact copies, and bin/cropper-sri-live against the live CDN.
class CropperAssetsIntegrityTest < Minitest::Test
  CSS_URL = "https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.css"
  JS_URL = "https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.js"
  CSS_SRI = "sha384-6LFfkTKLRlzFtgx8xsWyBdKGpcMMQTkv+dB7rAbugeJAu1Ym2q1Aji1cjHBG12Xh"
  JS_SRI = "sha384-jrOgQzBlDeUNdmQn3rUt/PZD+pdcRBdWd/HWRqRo+n2OR2QtGyjSaJC0GiCeH+ir"

  def test_the_stylesheet_is_pinned
    link = doc.at_css(%(link[rel="stylesheet"][href="#{CSS_URL}"]))

    refute_nil link, "the cropper stylesheet must load from the exact 1.6.2 URL"
    assert_equal CSS_SRI, link["integrity"]
    assert_equal "anonymous", link["crossorigin"]
  end

  def test_the_script_is_pinned
    script = doc.at_css(%(script[src="#{JS_URL}"]))

    refute_nil script, "the cropper script must load from the exact 1.6.2 URL (Turf's CSP names it)"
    assert_equal JS_SRI, script["integrity"]
    assert_equal "anonymous", script["crossorigin"]
    assert script.key?("defer"), "the script stays deferred"
  end

  # A third remote tag added later must not slip in unpinned.
  def test_every_remote_tag_carries_integrity
    remote = doc.css("link[href], script[src]").select { |n| (n["href"] || n["src"]).start_with?("http") }

    assert_equal 2, remote.size
    remote.each do |node|
      assert_match(/\Asha384-[A-Za-z0-9+\/]{64}\z/, node["integrity"].to_s, "#{node.name} lost its integrity")
      assert_equal "anonymous", node["crossorigin"], "#{node.name} lost crossorigin"
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
