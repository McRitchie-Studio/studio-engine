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
