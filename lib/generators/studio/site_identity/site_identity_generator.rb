# frozen_string_literal: true

require "rails/generators"

module Studio
  module Generators
    # Adopt the site identity + link-preview primitive in one repeatable step:
    #
    #   bin/rails g studio:site_identity \
    #     --title "Turf Monster" \
    #     --description "Skill-based pick'em contests with transparent payouts."
    #   bin/rails db:migrate
    #
    # What it does, each step idempotent (a second run changes nothing):
    #
    #   1. copies the engine's studio_site_identities migration into
    #      db/migrate, in exactly the form `studio_engine:install:migrations`
    #      writes (so that task later sees it and skips it) — and ONLY that
    #      migration, not every pending engine migration;
    #   2. writes the DRAFTED title and description into
    #      config/initializers/studio.rb as config.site_title /
    #      config.site_description (the standing convention: an agent drafts them
    #      when it sets an app up, Alex edits them at /admin/link_preview);
    #   3. includes Studio::LinkPreviewBots in ApplicationController, so preview
    #      fetchers get the slim page under Apple's 1 MiB limit.
    #
    # --own-tags is for an app that still writes its own og tags (turf-monster,
    # cyvasse): it sets config.link_preview_tags = false, so installing the table
    # does not add a second set before the app's own are deleted.
    class SiteIdentityGenerator < Rails::Generators::Base
      MIGRATION_NAME = "create_studio_site_identities"
      ENGINE_SCOPE = "studio_engine"
      INITIALIZER = "config/initializers/studio.rb"
      CONTROLLER = "app/controllers/application_controller.rb"

      class_option :title, type: :string, desc: "The drafted site title (config.site_title)"
      class_option :description, type: :string, desc: "The drafted site description (config.site_description)"
      class_option :own_tags, type: :boolean, default: false,
                              desc: "This app still writes its own og tags: set config.link_preview_tags = false"
      class_option :skip_bots, type: :boolean, default: false,
                               desc: "Do not include Studio::LinkPreviewBots in ApplicationController"

      def copy_migration
        existing = Dir.glob(File.join(destination_root, "db/migrate/*_#{MIGRATION_NAME}{,.#{ENGINE_SCOPE}}.rb"))
        if existing.any?
          say_status :identical, relative(existing.first), :blue
          return
        end

        source = self.class.engine_migration
        original_version = File.basename(source)[/\A\d+/]
        body = "# This migration comes from #{ENGINE_SCOPE} (originally #{original_version})\n#{File.read(source)}"
        create_file "db/migrate/#{self.class.next_version}_#{MIGRATION_NAME}.#{ENGINE_SCOPE}.rb", body
      end

      def configure_initializer
        path = File.join(destination_root, INITIALIZER)
        unless File.exist?(path)
          say_status :skip, "#{INITIALIZER} not found — add the site_title/site_description lines by hand", :yellow
          return
        end

        content = File.read(path)
        if content.include?("config.site_title")
          say_status :identical, "#{INITIALIZER} (config.site_title already set)", :blue
          return
        end

        anchor = content[/^Studio\.configure do \|(\w+)\|\n/]
        unless anchor
          say_status :skip, "#{INITIALIZER} has no `Studio.configure do |config|` block", :yellow
          return
        end

        inject_into_file INITIALIZER, initializer_block(anchor[/\|(\w+)\|/, 1]), after: anchor
      end

      def include_bot_concern
        return if options[:skip_bots]

        path = File.join(destination_root, CONTROLLER)
        return say_status(:skip, "#{CONTROLLER} not found", :yellow) unless File.exist?(path)
        return say_status(:identical, "#{CONTROLLER} (Studio::LinkPreviewBots)", :blue) if File.read(path).include?("Studio::LinkPreviewBots")

        inject_into_class CONTROLLER, "ApplicationController", <<~RUBY
          # Preview fetchers (iMessage, Slack, Discord, X...) get a slim page under
          # Apple's 1 MiB limit. studio-engine docs/LINK_PREVIEW.md.
          include Studio::LinkPreviewBots
        RUBY
      end

      def next_steps
        say <<~TEXT

          Site identity installed. Next:
            bin/rails db:migrate
            Visit /admin/link_preview to set the image and edit the title and description.
          Read the copy anywhere with Studio.site_identity (or studio_site_identity in a view).
        TEXT
      end

      def self.engine_migration
        File.expand_path("../../../../db/migrate/20260930120000_#{MIGRATION_NAME}.rb", __dir__)
      end

      def self.next_version
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      private

      def relative(path)
        path.delete_prefix("#{destination_root}/")
      end

      def initializer_block(var)
        title = options[:title].to_s.strip
        description = options[:description].to_s.strip
        lines = []
        lines << ""
        lines << "  # ---- Site identity + link preview (studio-engine docs/LINK_PREVIEW.md) ----"
        lines << "  # The DRAFTED title and description; the operator edits them at"
        lines << "  # /admin/link_preview, and Studio.site_identity reads the result."
        lines << (title.empty? ? "  # #{var}.site_title = \"Draft the site title\"" : "  #{var}.site_title = #{title.inspect}")
        lines << (description.empty? ? "  # #{var}.site_description = \"Draft one or two sentences\"" : "  #{var}.site_description = #{description.inspect}")
        if options[:own_tags]
          lines << "  # This app still writes its own og tags. Delete them, then remove this line."
          lines << "  #{var}.link_preview_tags = false"
        end
        lines << ""
        lines.join("\n") + "\n"
      end
    end
  end
end
