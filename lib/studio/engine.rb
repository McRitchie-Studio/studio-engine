module Studio
  class Engine < ::Rails::Engine
    initializer "studio.assets" do |app|
      app.config.assets.precompile += %w[
        studio/sticky_table_header.css
        studio/sticky_table_header.js
        studio/canvas_confetti.js
        studio/studio_confetti.js
        studio/sortable.js
      ]

      # The INHERITED default email banners (Studio::EmailImage). They ride the
      # gem so a brand-new app sends branded email on day one with an empty S3
      # bucket. Enumerated from disk rather than listed by hand so adding a
      # default is a one-file change. Sprockets hosts (mcritchie-studio,
      # turf-monster) need the explicit precompile entry; propshaft hosts
      # (mcritchie-industries, moms-app) serve everything on config.assets.paths
      # and ignore this list.
      # Named on the CLASS, not bare: an initializer block is instance_exec'd on
      # an Engine INSTANCE, where a bare call resolves to nothing and boots red.
      app.config.assets.precompile += Studio::Engine.default_email_banner_logical_paths
    end

    # Logical asset paths ("emails/magic-link.png") for every default banner the
    # gem ships.
    def self.default_email_banner_logical_paths
      Dir[File.expand_path("../../app/assets/images/emails/*", __dir__)]
        .select { |path| File.file?(path) }
        .map { |path| "emails/#{File.basename(path)}" }
        .sort
    end

    rake_tasks do
      load File.expand_path("../tasks/studio_email.rake", __dir__)
      load File.expand_path("../tasks/studio_ses.rake", __dir__)
    end

    config.after_initialize do
      # Validate the host app's User model satisfies the engine's contract.
      # See docs/USER_CONTRACT.md. Opt out with Studio.validate_user_contract = false.
      if defined?(::User) && ::User.is_a?(Class) &&
         (!defined?(::ActiveRecord::Base) || ::User.ancestors.include?(::ActiveRecord::Base))
        Studio.validate_user_contract!(::User)
      end
    end
  end
end
