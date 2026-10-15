# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"

# [integration] Studio::Storage is ON BY DEFAULT for an app that names its
# bucket. Each case boots test/support/storage_boot_probe.rb in its own process
# (Rails.env and ENV are fixed per process) with a config/storage.yml and a
# config/initializers/studio.rb of the case's own, and reads back what the app
# got:
#   - its storage.yml's names resolve, and `amazon` / `amazon_dev` resolve to
#     the engine's StudioTrashS3Service on the right bucket, with no initializer
#     of the app's own beyond naming the bucket;
#   - production with the R2 variables puts Studio::S3 and `amazon` on R2 and the
#     production bucket; QA (RAILS_ENV=production, QA_ENV) gets the dev bucket;
#   - production without them, or a retired switch anywhere, REFUSES THE BOOT;
#   - an app that names no bucket, opts out, or defines `amazon` itself keeps
#     exactly what it had.
class StorageBootTest < Minitest::Test
  PROBE = File.expand_path("../support/storage_boot_probe.rb", __dir__)
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  R2 = {
    "R2_ENDPOINT" => "https://probe-account.r2.cloudflarestorage.com",
    "R2_ACCESS_KEY_ID" => "probe-key", "R2_SECRET_ACCESS_KEY" => "probe-secret",
    "R2_PUBLIC_URL" => "https://assets.probe.example"
  }.freeze

  TEST_ONLY_STORAGE = <<~YAML
    test:
      service: Disk
      root: <%= Rails.root.join("tmp/storage") %>
  YAML

  # Every variable the primitive reads, cleared unless the case sets it, so the
  # shell this suite runs in cannot decide a case.
  CLEARED = (R2.keys + %w[ACTIVE_STORAGE_BACKEND STUDIO_S3_BACKEND QA_ENV DATABASE_URL SECRET_KEY_BASE_DUMMY]).to_h { |name| [name, nil] }

  def probe(env: "test", vars: {}, studio: 'config.s3_bucket_prefix = "probe-app"', storage: TEST_ONLY_STORAGE,
            service: env == "production" ? "amazon" : "test")
    Dir.mktmpdir("studio-storage-probe") do |root|
      FileUtils.mkdir_p(File.join(root, "config/initializers"))
      File.write(File.join(root, "config/storage.yml"), storage) if storage
      # host_schema_check off: the probe's in-memory database has no tables,
      # and the schema check is not the question here.
      File.write(File.join(root, "config/initializers/studio.rb"),
                 "Studio.configure do |config|\n  config.host_schema_check = false\n  #{studio}\nend\n")
      result = File.join(root, "result.json")
      process_env = CLEARED.merge(vars).merge(
        "RAILS_ENV" => env, "PROBE_ROOT" => root, "PROBE_RESULT" => result, "PROBE_SERVICE" => service,
        "BUNDLE_GEMFILE" => File.join(ENGINE_ROOT, "Gemfile")
      )
      output = IO.popen(process_env, [RbConfig.ruby, PROBE], err: %i[child out], &:read)
      assert $?.success?, "the #{env} probe crashed:\n#{output}"
      assert File.exist?(result), "the #{env} probe wrote no result:\n#{output}"
      JSON.parse(File.read(result))
    end
  end

  def assert_booted(result)
    assert result["booted"], "boot refused: #{result['error_class']}: #{result['error']}"
    assert_nil result["services_error"]
  end

  def assert_trash_service(result, name, bucket)
    entry = result.dig("services", name)
    refute_nil entry, "#{name} is not a service"
    assert_equal "ActiveStorage::Service::StudioTrashS3Service", entry["class"]
    assert_equal bucket, entry["bucket"]
  end

  def test_a_keyless_test_app_that_names_its_bucket_gets_the_trash_services
    result = probe

    assert_booted(result)
    assert_equal "ActiveStorage::Service::DiskService", result["default_service"], "storage.yml's own service stands"
    assert_trash_service(result, "amazon", "probe-app-dev")
    assert_trash_service(result, "amazon_dev", "probe-app-dev")
    assert_equal "https://r2-not-configured.invalid", result["s3_endpoint"], "Studio::S3 reaches nothing keyless"
    assert_equal "auto", result["s3_region"]
  end

  def test_production_with_the_r2_variables_runs_on_r2_and_the_production_bucket
    result = probe(env: "production", vars: R2,
                   studio: "config.s3_bucket_prefix = \"probe-app\"\n  config.storage_public_url_required = true")

    assert_booted(result)
    assert_equal "ActiveStorage::Service::StudioTrashS3Service", result["default_service"]
    assert_trash_service(result, "amazon", "probe-app-production")
    assert_trash_service(result, "amazon_dev", "probe-app-dev")
    assert_equal R2["R2_ENDPOINT"], result["s3_endpoint"]
    assert_equal R2["R2_PUBLIC_URL"], result["s3_public_url"]
    assert result["s3_access_key_id_set"]
  end

  def test_an_app_with_no_storage_yml_at_all_still_gets_its_services
    result = probe(env: "production", vars: R2, storage: nil)

    assert_booted(result)
    assert_trash_service(result, "amazon", "probe-app-production")
    assert_nil result.dig("services", "test")
  end

  def test_qa_boots_as_production_and_writes_the_dev_bucket
    result = probe(env: "production", vars: R2.merge("QA_ENV" => "true"))

    assert_booted(result)
    assert_trash_service(result, "amazon", "probe-app-dev")
  end

  def test_production_without_the_r2_variables_refuses_to_boot
    result = probe(env: "production", vars: R2.except("R2_SECRET_ACCESS_KEY"))

    refute result["booted"], "production booted without R2_SECRET_ACCESS_KEY"
    assert_equal "ArgumentError", result["error_class"]
    assert_match(/\AR2_SECRET_ACCESS_KEY must be set/, result["error"])
    assert_includes result["error"], "r2.probe-app"
  end

  # A Dockerfile's `SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile` boots
  # production keyless on purpose; it must not be refused.
  def test_a_keyless_precompile_boot_in_production_is_not_refused
    result = probe(env: "production", vars: { "SECRET_KEY_BASE_DUMMY" => "1" })

    assert_booted(result)
    assert_equal "https://r2-not-configured.invalid", result["s3_endpoint"]
  end

  def test_production_requires_the_public_url_only_when_the_app_does
    without = R2.except("R2_PUBLIC_URL")
    assert_booted(probe(env: "production", vars: without))

    result = probe(env: "production", vars: without,
                   studio: "config.s3_bucket_prefix = \"probe-app\"\n  config.storage_public_url_required = true")
    refute result["booted"]
    assert_match(/\AR2_PUBLIC_URL must be set/, result["error"])
  end

  def test_a_retired_switch_refuses_the_boot_even_in_test
    %w[ACTIVE_STORAGE_BACKEND STUDIO_S3_BACKEND].each do |name|
      result = probe(vars: { name => "mirror_to_r2" })

      refute result["booted"], "#{name}=mirror_to_r2 booted"
      assert_includes result["error"], "#{name}=\"mirror_to_r2\" names a retired stage"
    end
  end

  def test_an_app_that_names_no_bucket_gets_nothing
    result = probe(studio: "config.app_name = \"Probe\"", vars: { "STUDIO_S3_BACKEND" => "s3" })

    assert_booted(result)
    assert_nil result.dig("services", "amazon")
    assert_nil result["s3_endpoint"]
  end

  def test_an_app_that_owns_its_connection_and_defines_no_remote_service_gets_none
    result = probe(studio: "config.s3_bucket_prefix = \"probe-app\"\n  config.s3_endpoint = \"https://own.example\"")

    assert_booted(result)
    assert_nil result.dig("services", "amazon")
    assert_nil result.dig("services", "amazon_dev")
  end

  def test_an_app_that_opts_out_gets_nothing
    result = probe(studio: "config.s3_bucket_prefix = \"probe-app\"\n  config.manage_storage = false")

    assert_booted(result)
    assert_nil result.dig("services", "amazon")
    assert_nil result["s3_endpoint"]
  end

  # The pre-adoption state of all three apps: their own StorageBackend renders
  # `amazon` in storage.yml (or, keyless on turf-monster, nothing at all) and
  # configures Studio::S3 itself. The engine adds no service and touches no
  # connection: turf's suite pins that a keyless boot defines only local/test.
  def test_an_apps_own_amazon_service_and_studio_s3_connection_win
    storage = TEST_ONLY_STORAGE + <<~YAML
      amazon:
        service: StudioTrashS3
        bucket: the-apps-own-bucket
        region: auto
        endpoint: https://own.example
        access_key_id: own
        secret_access_key: own
    YAML
    studio = "config.s3_bucket_prefix = \"probe-app\"\n  config.s3_endpoint = \"https://own.example\""
    result = probe(storage: storage, studio: studio)

    assert_booted(result)
    assert_trash_service(result, "amazon", "the-apps-own-bucket")
    assert_nil result.dig("services", "amazon_dev"), "the engine added a service to an app that owns its connection"
    assert_equal "https://own.example", result["s3_endpoint"]
    assert_equal "us-east-2", result["s3_region"], "the engine touched a connection the app configured"
  end
end
