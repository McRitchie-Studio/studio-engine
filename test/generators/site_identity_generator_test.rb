# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "rails/generators"
require "rails/generators/test_case"
require_relative "../../lib/generators/studio/site_identity/site_identity_generator"

# [integration] `bin/rails g studio:site_identity` — the one repeatable adoption
# step for the site identity + link-preview primitive, run against a scratch app
# tree shaped like a real consumer (an initializer with a Studio.configure block
# and an ApplicationController that includes Studio::ErrorHandling).
class SiteIdentityGeneratorTest < Rails::Generators::TestCase
  tests Studio::Generators::SiteIdentityGenerator
  destination File.join(Dir.tmpdir, "studio-site-identity-generator-#{Process.pid}")

  INITIALIZER = <<~RUBY
    Studio.configure do |config|
      config.app_name = "Turf Monster"
    end
  RUBY

  CONTROLLER = <<~RUBY
    class ApplicationController < ActionController::Base
      include Studio::ErrorHandling
    end
  RUBY

  setup do
    prepare_destination
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
    FileUtils.mkdir_p(File.join(destination_root, "app/controllers"))
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    File.write(File.join(destination_root, "config/initializers/studio.rb"), INITIALIZER)
    File.write(File.join(destination_root, "app/controllers/application_controller.rb"), CONTROLLER)
  end

  teardown { FileUtils.rm_rf(destination_root) }

  def installed_migrations
    Dir.glob(File.join(destination_root, "db/migrate/*create_studio_site_identities*.rb"))
  end

  test "installs the one migration in the form install:migrations writes" do
    run_generator %w[--title Turf]

    assert_equal 1, installed_migrations.size
    path = installed_migrations.first
    assert_match(/\A\d{14}_create_studio_site_identities\.studio_engine\.rb\z/, File.basename(path),
                 "the .studio_engine suffix is what makes install:migrations skip it later")
    body = File.read(path)
    assert body.start_with?("# This migration comes from studio_engine (originally 20260930120000)\n")
    assert_includes body, "class CreateStudioSiteIdentities < ActiveRecord::Migration"
  end

  test "carries the drafted title and description into the initializer" do
    run_generator ["--title", "Turf Monster", "--description", "Skill-based pick'em \"contests\"."]

    assert_file "config/initializers/studio.rb" do |content|
      assert_includes content, %(config.site_title = "Turf Monster")
      assert_includes content, %(config.site_description = "Skill-based pick'em \\"contests\\".")
      refute_includes content, "link_preview_tags = false"
      assert_match(/Studio\.configure do \|config\|\n\n  # ---- Site identity/, content, "inside the configure block")
    end
  end

  test "without drafts it leaves commented prompts to fill in" do
    run_generator

    assert_file "config/initializers/studio.rb", /# config\.site_title = "Draft the site title"/
  end

  test "an app with its own og tags turns the engine's off" do
    run_generator %w[--own-tags --title Cyvasse]

    assert_file "config/initializers/studio.rb", /config\.link_preview_tags = false/
  end

  test "includes the preview-bot concern in ApplicationController" do
    run_generator

    assert_file "app/controllers/application_controller.rb" do |content|
      assert_includes content, "include Studio::LinkPreviewBots"
      assert_includes content, "include Studio::ErrorHandling"
    end
  end

  # cyvasse's adoption got the include at column 0. Every line the generator
  # writes into the class body sits at the body's two-space indent, and the
  # result is still a class that parses.
  test "writes the include indented inside the class body" do
    run_generator

    assert_file "app/controllers/application_controller.rb" do |content|
      assert_match(/^  include Studio::LinkPreviewBots$/, content)
      inserted = content.lines.select { |line| line.include?("LinkPreviewBots") || line.include?("Preview fetchers") }
      assert_operator inserted.size, :>=, 2
      inserted.each { |line| assert line.start_with?("  "), "unindented: #{line.inspect}" }
      assert_equal <<~RUBY, content
        class ApplicationController < ActionController::Base
          # Preview fetchers (iMessage, Slack, Discord, X...) get a slim page under
          # Apple's 1 MiB limit, and are exempt from allow_browser. studio-engine
          # docs/LINK_PREVIEW.md.
          include Studio::LinkPreviewBots
          include Studio::ErrorHandling
        end
      RUBY
    end
  end

  test "skip-bots leaves the controller alone" do
    run_generator %w[--skip-bots]

    assert_file "app/controllers/application_controller.rb" do |content|
      refute_includes content, "LinkPreviewBots"
    end
  end

  test "a second run changes nothing" do
    run_generator ["--title", "Turf Monster"]
    before = %w[config/initializers/studio.rb app/controllers/application_controller.rb].to_h do |f|
      [f, File.read(File.join(destination_root, f))]
    end

    run_generator ["--title", "Something else"]

    assert_equal 1, installed_migrations.size
    before.each { |file, content| assert_equal content, File.read(File.join(destination_root, file)), file }
  end

  test "an app that already installed it through install:migrations gets no second copy" do
    File.write(File.join(destination_root, "db/migrate/20261001000000_create_studio_site_identities.studio_engine.rb"), "# existing\n")

    run_generator

    assert_equal 1, installed_migrations.size
  end
end
