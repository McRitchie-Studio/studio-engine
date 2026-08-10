module Studio
  # DEPRECATED NAME — this is Studio::EmailCatalog now. Every method here just
  # forwards; there is no behavior in this file.
  #
  # Kept, and kept COMPLETE, for two reasons:
  #
  #   1. Engine 0.33 shipped this module as the registry's public name, so any
  #      app already on 0.33 is calling it.
  #   2. consumer-ci.yml runs each consumer's DEFAULT BRANCH suite against an
  #      engine PR, and mcritchie-studio's test/integration/studio_email_image_test.rb
  #      on `main` calls .url, .store and .record directly. Dropping any of them
  #      reddens that lane from the moment the PR opens, and nothing inside the
  #      engine PR can reach the consumer's main to fix it.
  #
  # Delete it once no consumer's main names it — the same staged retirement
  # /admin/email_images is on.
  #
  # Deliberately explicit rather than method_missing: a typo should still raise
  # NoMethodError here, and the delegated surface should be readable as a list.
  module EmailImage
    PURPOSE = EmailCatalog::PURPOSE
    ASPECT_RATIO = EmailCatalog::ASPECT_RATIO
    MAX_WIDTH = EmailCatalog::MAX_WIDTH

    module_function

    # Registry
    def register(...)   = EmailCatalog.register(...)
    def entries         = EmailCatalog.entries
    def entry(key)      = EmailCatalog.entry(key)
    def keys            = EmailCatalog.keys
    def known?(key)     = EmailCatalog.known?(key)
    def registered?(key) = EmailCatalog.registered?(key)
    def label(key)      = EmailCatalog.label(key)
    def variants        = EmailCatalog.variants
    def reset!          = EmailCatalog.reset!

    # Image resolution. `url` is the pre-registry contract — this app's own
    # image or nil — and must stay that way; see the note on EmailCatalog#url.
    def url(key)          = EmailCatalog.url(key)
    def resolved_url(key) = EmailCatalog.resolved_url(key)
    def preview_url(key)  = EmailCatalog.preview_url(key)
    def source(key)       = EmailCatalog.source(key)
    def app_owned?(key)   = EmailCatalog.app_owned?(key)
    def record(key)       = EmailCatalog.record(key)
    def default_url(key)  = EmailCatalog.default_url(key)
    def default_asset_path(key) = EmailCatalog.default_asset_path(key)

    # Writes
    def store(key, io:, content_type: nil) = EmailCatalog.store(key, io: io, content_type: content_type)
    def revert(key)        = EmailCatalog.revert(key)
    def uploads_available? = EmailCatalog.uploads_available?
    def table_ready?       = EmailCatalog.table_ready?

    # Origin resolution. Delegated because 0.33's suite asserted these directly.
    def mailer_asset_host = EmailCatalog.mailer_asset_host
    def mailer_protocol(options, host) = EmailCatalog.mailer_protocol(options, host)
    def mailer_port_suffix(options)    = EmailCatalog.mailer_port_suffix(options)
  end
end
