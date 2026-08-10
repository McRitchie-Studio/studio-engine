# frozen_string_literal: true

module Studio
  # The decision behind the engine's `studio.logger` initializer: given the
  # environment and the host's own choices, how large may the local log file
  # grow before it rotates — or should the engine keep its hands off entirely?
  #
  # Deliberately Rails-free so the whole decision table is unit-testable in
  # milliseconds. The initializer in Studio::Engine owns the other half of the
  # problem — running EARLY enough for the answer to matter — and that half is
  # covered by test/integration/log_rotation_test.rb, which boots real apps and
  # watches the file rotate on disk.
  module LogRotation
    # Deliberate values, not defaults. Rails' own `config.load_defaults "7.1"`
    # sets log_file_size to 100 MB for development AND test, each keeping one
    # rotated sibling — up to ~400 MB of log per checkout, times every worktree
    # on the machine. 16 MB still holds a full day of local request logs; 8 MB
    # covers a whole test run. Raising these is a decision, not a default.
    DEVELOPMENT_MAX_BYTES = 16 * 1024 * 1024
    TEST_MAX_BYTES        = 8 * 1024 * 1024

    # The environments whose logs are plain local files worth capping. Held here
    # rather than delegating to Rails.env.local? so that a future Rails adding a
    # third "local" environment cannot silently change where this engine writes
    # a cap.
    CAPPED_ENVIRONMENTS = %w[development test].freeze

    # Returns the byte cap to apply, or nil for "leave the host's logging
    # exactly as it is".
    #
    #   env          the Rails environment name
    #   host_logger  the host's own config.logger, if it named one
    #   override     Studio.local_log_max_bytes — false opts out, an Integer
    #                sets the host's own cap, nil means "use ours"
    def self.cap_for(env:, host_logger: nil, override: nil)
      # Production (and QA, which boots as production) hands its stream to the
      # platform. Never point that at a file.
      return nil unless CAPPED_ENVIRONMENTS.include?(env.to_s)
      # A host that named its own logger has already decided.
      return nil if host_logger
      # Explicit opt-out; Rails' own default returns.
      return nil if override == false
      # Explicit host cap.
      return override if override

      env.to_s == "test" ? TEST_MAX_BYTES : DEVELOPMENT_MAX_BYTES
    end
  end
end
