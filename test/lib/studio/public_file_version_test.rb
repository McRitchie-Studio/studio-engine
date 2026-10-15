# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# [unit] Studio::PublicFileVersion: a public file's link carries its content
# version, so a redrawn favicon is a URL no browser has cached; a host without
# the file gets the bare path, unchanged.
class PublicFileVersionTest < Minitest::Test
  V = Studio::PublicFileVersion

  def setup = V.reset!

  def test_a_file_gets_the_first_8_hex_of_its_sha256
    Dir.mktmpdir do |root|
      File.binwrite(File.join(root, "favicon.png"), "picture one")
      digest = Digest::SHA256.hexdigest("picture one")[0, 8]

      assert_equal "/favicon.png?v=#{digest}", V.path("/favicon.png", root: root)
      assert_equal digest, V.version("favicon.png", root: root)
    end
  end

  def test_a_redrawn_file_gets_a_new_version
    Dir.mktmpdir do |root|
      file = File.join(root, "favicon.png")
      File.binwrite(file, "picture one")
      first = V.version("/favicon.png", root: root)
      File.binwrite(file, "picture two, redrawn")
      File.utime(Time.now + 5, Time.now + 5, file)

      refute_equal first, V.version("/favicon.png", root: root)
      assert_equal Digest::SHA256.hexdigest("picture two, redrawn")[0, 8], V.version("/favicon.png", root: root)
    end
  end

  def test_no_file_no_root_or_a_directory_leaves_the_path_bare
    Dir.mktmpdir do |root|
      Dir.mkdir(File.join(root, "brand"))

      assert_equal "/favicon.png", V.path("/favicon.png", root: root)
      assert_equal "/brand", V.path("/brand", root: root)
      assert_equal "/favicon.png", V.path("/favicon.png", root: nil)
    end
  end
end
