# frozen_string_literal: true

require "fileutils"

# Where the engine lab (e2e/boot.rb) writes the files it serves, and the one-time
# clean-up of the place it used to write them.
#
# The lab serves its own public folder, never test/dummy/public: that folder is
# the minitest suite's public folder too, and a lab file left there (favicon.png)
# turned HeadScriptNonceTest red. test/lib/e2e_lab_public_test.rb holds the unit
# rules; test/integration/e2e_lab_residue_test.rb boots the real lab.
module E2eLabPublic
  # The paths an older lab wrote into test/dummy/public. Only these are removed.
  LEGACY_PATHS = %w[favicon.png e2e images/state-flags].freeze

  module_function

  # The lab's root folder: E2E_LAB_ROOT when set, else <engine>/tmp/e2e-lab.
  def root(engine_root, env = ENV)
    File.expand_path(env.fetch("E2E_LAB_ROOT", File.join(engine_root, "tmp", "e2e-lab")))
  end

  # Removes what an older lab wrote into the dummy's public folder, and the
  # folders that this empties. Any other file stays, and so does its folder.
  def remove_legacy!(dummy_public)
    LEGACY_PATHS.each { |path| FileUtils.rm_rf(File.join(dummy_public, path)) }
    [File.join(dummy_public, "images"), dummy_public].each do |dir|
      Dir.rmdir(dir) if Dir.exist?(dir) && Dir.empty?(dir)
    end
  end
end
