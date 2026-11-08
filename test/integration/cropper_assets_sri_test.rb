# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require "openssl"
require "base64"

# [integration] The vendored Cropper.js 1.6.2 files are the published release,
# and the integrity pinned in studio/_cropper_assets is their sha384. Offline:
#
#   · each file's sha512 equals the SRI cdnjs publishes for cropperjs 1.6.2
#     (cdnjs mirrors the npm package, and publishes sha512 only), recorded
#     below; and
#   · bin/cropper-sri-live re-fetches the npm tarball (checked against the
#     registry's dist.integrity), compares its dist files byte for byte, and
#     re-checks cdnjs. It needs the network, so it is a script, not the suite.
#
# A host's pipeline serves the files as they are only if it has nothing to
# rewrite: Propshaft rewrites a relative url() in CSS and a sourceMappingURL
# comment, and either would change the bytes and fail the digest in the
# browser. So neither may appear.
class CropperAssetsSriTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FILES = {
    "studio/cropper-1.6.2.min.js" => "app/assets/javascripts/studio/cropper-1.6.2.min.js",
    "studio/cropper-1.6.2.min.css" => "app/assets/stylesheets/studio/cropper-1.6.2.min.css",
  }.freeze

  # From https://api.cdnjs.com/libraries/cropperjs/1.6.2?fields=sri, 2026-10-24;
  # equal to the npm tarball's dist files, checked 2026-11-08.
  PUBLISHED_SHA512 = {
    "studio/cropper-1.6.2.min.js" => "sha512-JyCZjCOZoyeQZSd5+YEAcFgz2fowJ1F1hyJOXgtKu4llIa0KneLcidn5bwfutiehUTiOuK87A986BZJMko0eWQ==",
    "studio/cropper-1.6.2.min.css" => "sha512-UtLOu9C7NuThQhuXXrGwx9Jb/z9zPQJctuAgNUBK3Z6kkSYT9wJ+2+dh6klS+TDBCV9kNPBbAxbVD+vCcfGPaA==",
  }.freeze

  def test_the_vendored_files_are_the_published_release
    PUBLISHED_SHA512.each do |asset, sri|
      assert_equal sri, digest("SHA512", body(asset)), "#{FILES[asset]} is not the published 1.6.2 file"
    end
  end

  def test_each_pinned_integrity_is_the_sha384_of_its_file
    assert_equal FILES.keys.sort, pinned.keys.map { |path| path.delete_prefix("/") }.sort

    pinned.each do |path, integrity|
      asset = path.delete_prefix("/")
      assert_equal digest("SHA384", body(asset)), integrity, "#{path}: pinned integrity is not the file's sha384"
    end
  end

  def test_the_files_hold_nothing_a_pipeline_rewrites
    FILES.each_key do |asset|
      text = body(asset)
      refute_match(/sourceMappingURL/, text, "#{asset}: Propshaft rewrites a sourceMappingURL comment")
      text.scan(/url\(\s*["']?([^"')\s]+)/).flatten.each do |url|
        assert url.start_with?("data:"), "#{asset}: Propshaft rewrites url(#{url})"
      end
    end
  end

  private

  def body(asset) = File.binread(File.join(ROOT, FILES.fetch(asset)))

  def digest(algorithm, body)
    "#{algorithm.downcase}-#{Base64.strict_encode64(OpenSSL::Digest.digest(algorithm, body))}"
  end

  def pinned
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    doc = Nokogiri::HTML::DocumentFragment.parse(view.render(partial: "studio/cropper_assets"))
    doc.css("link[href], script[src]").to_h { |n| [n["href"] || n["src"], n["integrity"]] }
  end
end
