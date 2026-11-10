# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../e2e/lab_public"

# [unit] The engine lab's public folder (e2e/lab_public.rb): where it lives, and
# the one-time clean-up of what an older lab wrote into test/dummy/public. The
# clean-up deletes files, so it must delete only the lab's own.
class E2eLabPublicTest < Minitest::Test
  def test_the_lab_root_defaults_to_the_engine_tmp_folder
    assert_equal "/engine/tmp/e2e-lab", E2eLabPublic.root("/engine", {})
  end

  def test_e2e_lab_root_moves_the_lab
    assert_equal "/elsewhere/lab", E2eLabPublic.root("/engine", { "E2E_LAB_ROOT" => "/elsewhere/lab" })
  end

  def test_it_removes_every_legacy_path_and_the_folders_that_empties
    Dir.mktmpdir do |dir|
      public = File.join(dir, "public")
      write(public, "favicon.png")
      write(public, "e2e/tailwind.css")
      write(public, "e2e/js/studio/alpine.js")
      write(public, "images/state-flags/thumb/co.png")

      E2eLabPublic.remove_legacy!(public)

      refute Dir.exist?(public), "an emptied dummy public folder is removed, as git has it"
    end
  end

  def test_it_keeps_every_file_the_lab_did_not_write
    Dir.mktmpdir do |dir|
      public = File.join(dir, "public")
      write(public, "favicon.png")
      write(public, "og.png")
      write(public, "kit-test/logo.svg")
      write(public, "images/other.png")
      write(public, "images/state-flags/thumb/co.png")

      E2eLabPublic.remove_legacy!(public)

      remaining = Dir.glob("**/*", base: public).select { |path| File.file?(File.join(public, path)) }.sort
      assert_equal %w[images/other.png kit-test/logo.svg og.png], remaining
    end
  end

  def test_a_missing_dummy_public_folder_is_not_an_error
    Dir.mktmpdir do |dir|
      E2eLabPublic.remove_legacy!(File.join(dir, "public"))
      refute Dir.exist?(File.join(dir, "public"))
    end
  end

  private

  def write(root, path)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "x")
  end
end
