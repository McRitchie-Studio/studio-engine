# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

require_relative "../../db/migrate/20260620000002_allow_null_image_cache_owner"

# [integration] `allow_null_image_cache_owner` ALTERS `image_caches`, which is an
# app-owned table the engine cannot assume exists. Unguarded it raised and failed
# the whole `db:migrate` on any app without it — moms-app hit exactly that.
#
# Deleting the copied migration is NOT a workaround: `install:migrations` builds
# its skip-list from the files PRESENT, so a deleted copy comes back with a fresh
# timestamp on the next upgrade (verified by re-running the task against a real
# consumer). The guard therefore has to live in the migration, and this pins both
# halves of it — that it no-ops when the table is absent, and that it still does
# its job when the table is there.
class ImageCacheMigrationGuardTest < ActiveSupport::TestCase
  def connection = ActiveRecord::Base.connection

  setup do
    @was_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
  end

  teardown do
    ActiveRecord::Migration.verbose = @was_verbose
    connection.drop_table(:image_caches, if_exists: true)
  end

  test "no-ops on an app with no image_caches table" do
    connection.drop_table(:image_caches, if_exists: true)
    assert_not connection.table_exists?(:image_caches), "precondition: table must be absent"

    # The bug was a raise here, which failed the consumer's entire db:migrate.
    AllowNullImageCacheOwner.new.migrate(:up)

    assert_not connection.table_exists?(:image_caches), "the guard must not create the table either"
  end

  # The guard must not have turned the migration into a no-op everywhere — assert
  # the effect it exists for, on an app that DOES own the table.
  test "still relaxes the owner columns when the table exists" do
    connection.drop_table(:image_caches, if_exists: true)
    connection.create_table :image_caches do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
    end

    assert_not nullable?(:owner_type), "precondition: owner_type starts NOT NULL"
    assert_not nullable?(:owner_id), "precondition: owner_id starts NOT NULL"

    AllowNullImageCacheOwner.new.migrate(:up)

    assert nullable?(:owner_type), "owner_type must become nullable"
    assert nullable?(:owner_id), "owner_id must become nullable"
  end

  private

  def nullable?(column_name)
    connection.columns(:image_caches).find { |c| c.name == column_name.to_s }.null
  end
end
