class ErrorLog < ApplicationRecord
  # `slug` is unique (RequireSlugsOnEngineTables) and becomes NOT NULL a release
  # later, so every insert carries one, including a host's bare
  # `ErrorLog.create!`. Sluggable writes a unique placeholder before the insert
  # and settles it to `error-log-<id>` right after, inside the create, once the
  # id exists.
  include Sluggable

  belongs_to :target, polymorphic: true, optional: true
  belongs_to :parent, polymorphic: true, optional: true

  def inspect_field
    read_attribute(:inspect)
  end

  def self.capture!(exception)
    cleaned = Rails.backtrace_cleaner.clean(exception.backtrace || [])

    # Don't store exception.inspect — Ruby's default inspect for many error
    # subclasses includes ivar dumps that can carry secrets (API keys read
    # from ENV into a local, request bodies, etc.). Store just class +
    # truncated message instead. Apps that need richer context should
    # capture it explicitly via target/parent or via Sentry's PII rules.
    safe_inspect = "#<#{exception.class}: #{exception.message.to_s[0, 1000]}>"

    log = create!(
      message: exception.message,
      inspect: safe_inspect,
      backtrace: cleaned.to_json
    )

    # Fan out to Sentry if the host app loaded sentry-ruby. Guard with
    # respond_to? so we don't blow up on old SDK versions. The DB ErrorLog
    # row remains the local triage view; Sentry is the paging layer.
    if defined?(::Sentry) && ::Sentry.respond_to?(:capture_exception)
      begin
        ::Sentry.capture_exception(exception) do |scope|
          scope.set_tags(error_log_slug: log.slug)
        end
      rescue => e
        Rails.logger.warn "[ErrorLog.capture!] Sentry delivery failed: #{e.class}: #{e.message}"
      end
    end

    log
  end

  private

  # The id does not exist before the insert, so the first call returns a unique
  # placeholder; Sluggable calls it again after the insert.
  def name_slug
    id ? "error-log-#{id}" : "error-log-new-#{SecureRandom.hex(8)}"
  end
end
