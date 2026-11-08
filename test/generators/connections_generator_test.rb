# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "rails/generators"
require "rails/generators/test_case"
require_relative "../../lib/generators/studio/connections/connections_generator"

# [integration] `bin/rails g studio:connections`: the one install step for the
# connections tooling, against a scratch app tree.
class ConnectionsGeneratorTest < Rails::Generators::TestCase
  tests Studio::Generators::ConnectionsGenerator
  destination File.join(Dir.tmpdir, "studio-connections-generator-#{Process.pid}")

  setup do
    prepare_destination
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
  end

  teardown { FileUtils.rm_rf(destination_root) }

  def installed_migrations = Dir.glob(File.join(destination_root, "db/migrate/*create_studio_connections*.rb"))

  test "installs the one migration in the form install:migrations writes" do
    run_generator

    path = installed_migrations.sole
    assert_match(/\A\d{14}_create_studio_connections\.studio_engine\.rb\z/, File.basename(path))
    body = File.read(path)
    assert body.start_with?("# This migration comes from studio_engine (originally 20261108130000)\n")
    assert_includes body, "class CreateStudioConnections < ActiveRecord::Migration"
    assert_equal 1, Dir.glob(File.join(destination_root, "db/migrate/*.rb")).size, "only the connections migration"
  end

  test "writes a commented initializer that declares no provider" do
    run_generator

    body = File.read(File.join(destination_root, "config/initializers/studio_connections.rb"))
    assert_includes body, "Studio.define_connection :files"
    assert(body.lines.grep(/define_connection/).all? { _1.lstrip.start_with?("#") }, "every provider line is a comment")
    assert_match(/account_format: \/\\A\\d\{1,20\}\\z\//, body, "the example's regexp survives the heredoc")
  end

  test "a second run changes nothing" do
    run_generator
    File.write(File.join(destination_root, "config/initializers/studio_connections.rb"), "# mine\n")
    run_generator

    assert_equal 1, installed_migrations.size
    assert_equal "# mine\n", File.read(File.join(destination_root, "config/initializers/studio_connections.rb"))
  end

  test "skips the migration when install:migrations already copied it" do
    File.write(File.join(destination_root, "db/migrate/20261109000000_create_studio_connections.studio_engine.rb"), "# copied\n")
    run_generator

    assert_equal 1, installed_migrations.size
  end
end
