# frozen_string_literal: true

module Studio
  # studio/_page_header's one piece of Ruby: the deprecation note for its old free-HTML
  # slot (docs/PAGE_HEADER.md, "The four kinds of control").
  #
  # actions_html still renders for one release. In development only, the first render
  # that passes it writes one warning to the log per call site, so a host sees each
  # page it has to move and no page repeats.
  module PageHeader
    ACTIONS_HTML_WARNING =
      "studio/_page_header: actions_html is deprecated and goes in the next release. " \
      "Pass tabs: or anchors:, menu:, action: and tools_html: instead (docs/PAGE_HEADER.md)."

    @warned = {}
    @mutex = Mutex.new

    class << self
      # site: the caller's "path:line", so each page warns once. env and logger default to
      # Rails' and are injectable for a test.
      def deprecate_actions_html(site: nil, env: rails_env, logger: rails_logger)
        return false unless warning_enabled?(env: env) && logger

        key = site.to_s
        first = @mutex.synchronize { @warned[key] ? false : (@warned[key] = true) }
        return false unless first

        logger.warn([ACTIONS_HTML_WARNING, (" Called from #{site}." if site)].compact.join)
        true
      end

      # Whether a render should look for its call site at all: development only, so no
      # other environment pays for the caller walk.
      def warning_enabled?(env: rails_env)
        env.to_s == "development"
      end

      def reset_warnings!
        @mutex.synchronize { @warned.clear }
      end

      private

      def rails_env
        defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env : nil
      end

      def rails_logger
        defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
      end
    end
  end
end
