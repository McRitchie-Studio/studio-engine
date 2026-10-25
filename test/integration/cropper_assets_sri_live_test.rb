# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require "net/http"
require "openssl"
require "base64"
require "json"

# [integration] The integrity pinned in studio/_cropper_assets equals sha384 of
# the bytes cdnjs serves, and those bytes are the canonical release: their
# sha512 equals the SRI cdnjs publishes for cropperjs 1.6.2 (cdnjs publishes
# sha512 only, so that is the cross-check).
#
# It needs the network, so it runs only when asked:
#   CDN_SRI_LIVE=1 ruby -Itest test/integration/cropper_assets_sri_live_test.rb
# Run it whenever the pinned version or its hashes change.
class CropperAssetsSriLiveTest < Minitest::Test
  def setup
    skip "set CDN_SRI_LIVE=1 to fetch from cdnjs" unless ENV["CDN_SRI_LIVE"] == "1"
  end

  def test_pinned_hashes_match_the_live_cdnjs_files
    published = JSON.parse(get("https://api.cdnjs.com/libraries/cropperjs/1.6.2?fields=sri")).fetch("sri")
    tags = pinned_tags

    assert_equal 2, tags.size
    tags.each do |url, integrity|
      body = get(url)
      file = url.split("/").last

      assert_equal published.fetch(file), "sha512-#{Base64.strict_encode64(OpenSSL::Digest.digest("SHA512", body))}",
        "#{file}: fetched bytes differ from cdnjs's published SRI"
      assert_equal "sha384-#{Base64.strict_encode64(OpenSSL::Digest.digest("SHA384", body))}", integrity,
        "#{file}: pinned integrity does not match the live file"
    end
  end

  private

  def pinned_tags
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    doc = Nokogiri::HTML::DocumentFragment.parse(view.render(partial: "studio/cropper_assets"))
    doc.css("link[href], script[src]").map { |n| [n["href"] || n["src"], n["integrity"]] }
  end

  def get(url)
    response = Net::HTTP.get_response(URI(url))
    response = Net::HTTP.get_response(URI(response["location"])) if response.is_a?(Net::HTTPRedirection)
    assert_kind_of Net::HTTPSuccess, response, "GET #{url}"
    response.body
  end
end
