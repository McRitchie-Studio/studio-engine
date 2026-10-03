# frozen_string_literal: true

require "bundler/setup"
ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"
require "rake"

# [integration] A consuming app adopts the trash grace period by writing
# `service: StudioTrashS3` in config/storage.yml, and runs the restore through
# the engine's rake tasks. Both are BOOT-TIME contracts, so they are proved
# against the booted dummy app rather than a hand-required file:
#
#   - Active Storage's own Configurator turns "StudioTrashS3" into
#     ActiveStorage::Service::StudioTrashS3Service by REQUIRING
#     "active_storage/service/studio_trash_s3_service" off the load path. If the
#     file moved, or were left to Zeitwerk, an app would fail to boot.
#   - The service the Configurator builds trashes, and in this non-production
#     process refuses a production bucket.
#   - The engine registers studio:trash:list and :restore, each exactly once.
class StudioTrashS3ServiceResolutionTest < ActiveSupport::TestCase
  def configure(bucket)
    ActiveStorage::Service.configure(
      :trash,
      { trash: { service: "StudioTrashS3", bucket: bucket, region: "auto", stub_responses: true } }
    )
  end

  test "storage.yml's StudioTrashS3 resolves to the engine's service" do
    service = configure("turf-monster-dev")

    assert_instance_of ActiveStorage::Service::StudioTrashS3Service, service
    assert_equal "trash", service.name.to_s
  end

  test "the configured service trashes a delete" do
    service = configure("turf-monster-dev")
    client = service.client.client
    client.stub_responses(:head_object, { content_length: 3, content_type: "image/png" })

    service.delete("abc123")
    assert_equal %i[head_object copy_object delete_object],
                 client.api_requests.map { |request| request[:operation_name] }
  end

  test "a test-env process may not delete from a production bucket" do
    service = configure("turf-monster-production")

    assert_raises(Studio::S3::Trash::ProductionBucketRefused) { service.delete("abc123") }
    assert_empty service.client.client.api_requests
  end

  # EXACTLY once. A Rails engine already loads every lib/tasks/*.rake on its own
  # (Engine#run_tasks_blocks), so a second, explicit `load` in the rake_tasks
  # block appends a second copy of each action: restore would copy, then run
  # again and abort on its own conflict. That was this file's first draft.
  test "the engine registers each trash rake task exactly once" do
    Rake.application = Rake::Application.new
    Studio::Engine.instance.load_tasks

    %w[studio:trash:list studio:trash:restore].each do |name|
      assert Rake::Task.task_defined?(name), "#{name} is not registered"
      assert_equal 1, Rake::Task[name].actions.size, "#{name} is loaded more than once"
    end
  ensure
    Rake.application = Rake::Application.new
  end
end
