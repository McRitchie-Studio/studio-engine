# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"
require "openssl"
require "base64"

# [integration] The integrity pinned in studio/_cropper_assets is the sha384 of
# the real Cropper.js 1.6.2 files, checked offline against byte-exact copies
# (test/fixtures/files/cropperjs-1.6.2). Two facts tie those copies to cdnjs:
#
#   · their sha512 equals the SRI cdnjs publishes for cropperjs 1.6.2 (it
#     publishes sha512 only), recorded below; and
#   · bin/cropper-sri-live re-fetches both files and re-checks both digests.
#     It needs the network, so it is a script, not part of the suite.
#
# The browser lane serves these same copies for the two cdnjs URLs
# (e2e/helpers.js, blockOffsiteRequests), so a hash bump without new copies
# fails here before it fails there.
class CropperAssetsSriTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures/files/cropperjs-1.6.2", __dir__)
  BASE = "https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/"

  # From https://api.cdnjs.com/libraries/cropperjs/1.6.2?fields=sri, 2026-10-24.
  CDNJS_SHA512 = {
    "cropper.min.js" => "sha512-JyCZjCOZoyeQZSd5+YEAcFgz2fowJ1F1hyJOXgtKu4llIa0KneLcidn5bwfutiehUTiOuK87A986BZJMko0eWQ==",
    "cropper.min.css" => "sha512-UtLOu9C7NuThQhuXXrGwx9Jb/z9zPQJctuAgNUBK3Z6kkSYT9wJ+2+dh6klS+TDBCV9kNPBbAxbVD+vCcfGPaA==",
  }.freeze

  def test_the_copies_are_the_files_cdnjs_publishes
    CDNJS_SHA512.each do |file, sri|
      assert_equal sri, digest("SHA512", File.binread(File.join(FIXTURES, file))), "#{file} is not cdnjs's 1.6.2 file"
    end
  end

  def test_each_pinned_integrity_is_the_sha384_of_its_file
    assert_equal CDNJS_SHA512.keys.sort, pinned.keys.map { |url| url.delete_prefix(BASE) }.sort

    pinned.each do |url, integrity|
      body = File.binread(File.join(FIXTURES, url.delete_prefix(BASE)))
      assert_equal digest("SHA384", body), integrity, "#{url}: pinned integrity is not the file's sha384"
    end
  end

  private

  def digest(algorithm, body)
    "#{algorithm.downcase}-#{Base64.strict_encode64(OpenSSL::Digest.digest(algorithm, body))}"
  end

  def pinned
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    doc = Nokogiri::HTML::DocumentFragment.parse(view.render(partial: "studio/cropper_assets"))
    doc.css("link[href], script[src]").to_h { |n| [n["href"] || n["src"], n["integrity"]] }
  end
end
