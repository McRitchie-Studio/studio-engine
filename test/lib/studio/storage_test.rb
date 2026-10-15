# frozen_string_literal: true

require_relative "../../test_helper"
require "tmpdir"
require_relative "../../../lib/studio/storage"

# [unit] Studio::Storage: the one copy of the R2 rules the hub, turf-monster and
# mcritchie-industries each hand-wrote as StorageBackend. Every method takes its
# inputs as arguments, so each rule is pinned without booting an app; the boot
# itself is test/integration/storage_boot_test.rb.
#
# Rails.env is stubbed for #strict? and #bucket's default the way
# s3_qa_environment_test.rb does it: the unit env carries no Rails.env, and
# bin/release-check runs each file in its own process, so the accessor added
# here cannot leak into a sibling.
module Rails
  class << self
    attr_accessor :env unless method_defined?(:env)
  end

  StorageFakeEnv = Struct.new(:name) do
    def production? = name == "production"
  end
end

class StudioStorageTest < Minitest::Test
  S = Studio::Storage
  R2_ENV = {
    "R2_ENDPOINT" => "https://account.r2.cloudflarestorage.com",
    "R2_ACCESS_KEY_ID" => "key-id",
    "R2_SECRET_ACCESS_KEY" => "secret",
    "R2_PUBLIC_URL" => "https://assets.example.com"
  }.freeze

  def setup
    @prefix = Studio.s3_bucket_prefix
    @rails_env = Rails.env
    Studio.s3_bucket_prefix = "turf-monster"
    Rails.env = Rails::StorageFakeEnv.new("test")
  end

  def teardown
    Studio.s3_bucket_prefix = @prefix
    Rails.env = @rails_env
  end

  def in_env(name)
    previous = Rails.env
    Rails.env = Rails::StorageFakeEnv.new(name)
    yield
  ensure
    Rails.env = previous
  end

  # ---- unset means R2 -------------------------------------------------------

  def test_unset_or_blank_switch_means_r2
    S::SWITCHES.each do |name|
      reader = name == "ACTIVE_STORAGE_BACKEND" ? :active_storage_stage : :studio_s3_stage
      assert_equal "r2", S.public_send(reader, {})
      assert_equal "r2", S.public_send(reader, { name => "" })
      assert_equal "r2", S.public_send(reader, { name => "  " })
      assert_equal "r2", S.public_send(reader, { name => "r2" })
      assert_equal "r2", S.public_send(reader, { name => " r2 " })
    end
  end

  # ---- each retired value raises --------------------------------------------

  def test_each_retired_value_raises_naming_the_variable_on_both_switches
    S::SWITCHES.each do |name|
      reader = name == "ACTIVE_STORAGE_BACKEND" ? :active_storage_stage : :studio_s3_stage
      %w[s3 mirror_to_r2 mirror_to_s3].each do |retired|
        error = assert_raises(ArgumentError) { S.public_send(reader, { name => retired }) }
        assert_includes error.message, "#{name}=#{retired.inspect}"
        assert_includes error.message, "retired"
      end
    end
  end

  def test_an_unknown_value_raises_and_is_not_called_retired
    %w[R2 cloudflare r3].each do |value|
      error = assert_raises(ArgumentError) { S.active_storage_stage({ "ACTIVE_STORAGE_BACKEND" => value }) }
      assert_includes error.message, "is not a storage backend"
      refute_includes error.message, "retired"
    end
  end

  def test_validate_raises_on_a_retired_switch_in_every_environment
    [true, false].each do |strict|
      assert_raises(ArgumentError) { S.validate!(R2_ENV.merge("ACTIVE_STORAGE_BACKEND" => "s3"), strict: strict) }
      assert_raises(ArgumentError) { S.validate!(R2_ENV.merge("STUDIO_S3_BACKEND" => "mirror_to_r2"), strict: strict) }
      # Even when the connection is the app's own business, the switches are not.
      assert_raises(ArgumentError) do
        S.validate!({ "STUDIO_S3_BACKEND" => "mirror_to_s3" }, strict: strict, check_connection: false)
      end
    end
  end

  def test_studio_s3_settings_reads_its_switch_first
    error = assert_raises(ArgumentError) { S.studio_s3_settings(R2_ENV.merge("STUDIO_S3_BACKEND" => "s3"), strict: true) }
    assert_includes error.message, "STUDIO_S3_BACKEND"
  end

  # ---- the connection and missing credentials --------------------------------

  def test_a_complete_connection_in_production
    r2 = S.connection(R2_ENV, strict: true, public_url_required: true)
    assert_equal({ endpoint: R2_ENV["R2_ENDPOINT"], access_key_id: "key-id", secret_access_key: "secret",
                   public_url: "https://assets.example.com" }, r2)
    assert S.validate!(R2_ENV, strict: true, public_url_required: true)
  end

  def test_production_names_every_missing_variable_and_the_credential_source
    error = assert_raises(ArgumentError) { S.connection({}, strict: true, public_url_required: true, prefix: "turf-monster") }
    %w[R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_URL].each { |name| assert_includes error.message, name }
    assert_includes error.message, "refuse to boot"
    assert_includes error.message, "1Password item r2.turf-monster"

    S::CONNECTION_VARIABLES.each do |name|
      error = assert_raises(ArgumentError) { S.validate!(R2_ENV.except(name), strict: true) }
      assert_match(/\A#{name} must be set/, error.message)
      error = assert_raises(ArgumentError) { S.validate!(R2_ENV.merge(name => "  "), strict: true) }
      assert_match(/\A#{name} must be set/, error.message)
    end
  end

  def test_the_public_url_is_required_only_when_the_app_says_so
    env = R2_ENV.except("R2_PUBLIC_URL")

    assert_nil S.connection(env, strict: true, public_url_required: false)[:public_url]
    refute S.studio_s3_settings(env, strict: true, public_url_required: false).key?(:s3_public_url)
    assert_match(/\AR2_PUBLIC_URL must be set/,
                 assert_raises(ArgumentError) { S.connection(env, strict: true, public_url_required: true) }.message)
  end

  def test_a_keyless_non_production_process_boots_on_placeholders_that_reach_nothing
    r2 = S.connection({}, strict: false, public_url_required: true)
    assert_equal "https://r2-not-configured.invalid", r2[:endpoint]
    assert_equal "r2-not-configured", r2[:access_key_id]
    assert_equal "r2-not-configured", r2[:secret_access_key]
    assert_equal "https://r2-not-configured.invalid", r2[:public_url]
    assert S.validate!({}, strict: false)

    assert_nil S.connection({}, strict: false, public_url_required: false)[:public_url]
  end

  def test_half_a_configuration_raises_outside_production_too
    error = assert_raises(ArgumentError) do
      S.connection(R2_ENV.slice("R2_ENDPOINT"), strict: false, public_url_required: false)
    end
    assert_includes error.message, "R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY must be set"
    assert_includes error.message, "R2_ENDPOINT is set"
  end

  def test_configured_answers_no_on_placeholders
    assert S.configured?(R2_ENV, public_url_required: true)
    refute S.configured?({}, public_url_required: false)
    refute S.configured?(R2_ENV.except("R2_PUBLIC_URL"), public_url_required: true)
    assert S.configured?(R2_ENV.except("R2_PUBLIC_URL"), public_url_required: false)
  end

  def test_remote_in_development_when_any_variable_is_set
    refute S.remote_in_development?({})
    assert S.remote_in_development?(R2_ENV.slice("R2_PUBLIC_URL"))
    assert S.remote_in_development?(R2_ENV)
  end

  def test_credential_hint_names_the_variables
    assert_includes S.credential_hint(public_url_required: true), "R2_PUBLIC_URL"
    refute_includes S.credential_hint(public_url_required: false), "R2_PUBLIC_URL"
    assert_includes S.credential_hint(public_url_required: false), ".env.development"
  end

  # ---- strictness follows Rails.env -----------------------------------------

  def test_strict_is_rails_production_which_includes_qa
    refute S.strict?
    in_env("production") { assert S.strict? }
    in_env("development") { refute S.strict? }
  end

  # moms-app's rule: `SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile` boots
  # production with no secrets on purpose. It boots on placeholders; the bucket
  # is still production's.
  def test_the_precompile_flag_relaxes_strictness_but_not_the_bucket
    in_env("production") do
      refute S.strict?({ "SECRET_KEY_BASE_DUMMY" => "1" })
      assert S.strict?({ "SECRET_KEY_BASE_DUMMY" => " " })
      assert S.validate!({ "SECRET_KEY_BASE_DUMMY" => "1" }, strict: S.strict?({ "SECRET_KEY_BASE_DUMMY" => "1" }))
      assert S.production_environment?({ "SECRET_KEY_BASE_DUMMY" => "1" })
    end
  end

  # ---- bucket names per environment -----------------------------------------

  def test_bucket_names_per_environment
    assert_equal "turf-monster-dev", S.bucket, "test resolves the dev bucket"
    in_env("development") { assert_equal "turf-monster-dev", S.bucket }
    in_env("production") do
      assert_equal "turf-monster-production", S.bucket(production: S.production_environment?({}))
      # QA boots RAILS_ENV=production; QA_ENV sends it to the dev bucket.
      assert_equal "turf-monster-dev", S.bucket(production: S.production_environment?({ "QA_ENV" => "true" }))
    end
    assert_equal "mcritchie-industries-production", S.bucket("mcritchie-industries", production: true)
    assert_equal "mcritchie-industries-dev", S.dev_bucket("mcritchie-industries")
  end

  def test_bucket_without_a_prefix_raises
    assert_raises(ArgumentError) { S.bucket(nil, production: false) }
    assert_raises(ArgumentError) { S.bucket(" ", production: true) }
  end

  def test_active_storage_services_are_trash_services_on_r2
    services = S.active_storage_services(R2_ENV, prefix: "mcritchie-studio", strict: true, production: true)

    assert_equal %w[amazon amazon_dev], services.keys
    assert_equal "mcritchie-studio-production", services["amazon"]["bucket"]
    assert_equal "mcritchie-studio-dev", services["amazon_dev"]["bucket"]
    services.each_value do |config|
      assert_equal "StudioTrashS3", config["service"]
      assert_equal "auto", config["region"]
      assert_equal R2_ENV["R2_ENDPOINT"], config["endpoint"]
      assert_equal "when_required", config["request_checksum_calculation"]
      assert_equal "when_required", config["response_checksum_validation"]
    end

    qa = S.active_storage_services(R2_ENV, prefix: "mcritchie-studio", strict: true, production: false)
    assert_equal "mcritchie-studio-dev", qa["amazon"]["bucket"], "QA must never write the production bucket"
  end

  def test_active_storage_services_never_require_the_public_url
    services = S.active_storage_services(R2_ENV.except("R2_PUBLIC_URL"), prefix: "x", strict: true, production: true)
    assert_equal "x-production", services["amazon"]["bucket"]
  end

  # ---- merging under the app's own services ---------------------------------

  def test_the_apps_own_service_of_the_same_name_wins
    own = { "test" => { "service" => "Disk" }, "amazon" => { "service" => "S3", "bucket" => "mine" } }
    merged = S.merge_services(own, R2_ENV, prefix: "x", strict: true, production: true)

    assert_equal({ "service" => "S3", "bucket" => "mine" }, merged["amazon"])
    assert_equal "StudioTrashS3", merged["amazon_dev"]["service"]
    assert_equal({ "service" => "Disk" }, merged["test"])
  end

  def test_an_app_defining_both_names_computes_nothing
    own = { amazon: { service: "S3" }, amazon_dev: { service: "S3" } }
    # strict with no variables would raise if the engine built its services.
    assert_equal own, S.merge_services(own, {}, prefix: "x", strict: true, production: true)
  end

  def test_storage_file_configurations_reads_what_active_storage_reads
    Dir.mktmpdir do |root|
      assert_equal({}, S.storage_file_configurations(root, "test"))

      FileUtils.mkdir_p(File.join(root, "config/storage"))
      File.write(File.join(root, "config/storage.yml"), "local:\n  service: Disk\n  root: <%= 'tmp' %>\n")
      assert_equal({ "local" => { "service" => "Disk", "root" => "tmp" } }, S.storage_file_configurations(root, "test"))

      File.write(File.join(root, "config/storage/test.yml"), "only:\n  service: Disk\n")
      assert_equal({ "only" => { "service" => "Disk" } }, S.storage_file_configurations(root, "test"))
    end
  end

  # ---- the Studio::S3 hand-off ----------------------------------------------

  FakeConfig = Struct.new(:s3_bucket_prefix, :s3_endpoint, :s3_region, :s3_access_key_id,
                          :s3_secret_access_key, :s3_public_url)

  def test_apply_points_studio_s3_at_r2_when_the_app_left_it_unset
    config = FakeConfig.new("turf-monster", nil, "us-east-2")

    assert S.apply_studio_s3_settings!(config, R2_ENV, strict: true, public_url_required: true)
    assert_equal R2_ENV["R2_ENDPOINT"], config.s3_endpoint
    assert_equal "auto", config.s3_region
    assert_equal "key-id", config.s3_access_key_id
    assert_equal "secret", config.s3_secret_access_key
    assert_equal "https://assets.example.com", config.s3_public_url
  end

  def test_apply_stands_back_when_the_app_configured_the_connection
    config = FakeConfig.new("turf-monster", "https://own.example", "auto", "a", "b", nil)

    refute S.apply_studio_s3_settings!(config, {}, strict: true, public_url_required: true)
    assert_equal "https://own.example", config.s3_endpoint
  end

  def test_ownership_follows_whether_the_app_configured_the_connection
    S.reset_ownership!
    assert S.owns_connection?(FakeConfig.new("x", nil)), "before boot: s3_endpoint unset means the engine owns it"
    refute S.owns_connection?(FakeConfig.new("x", "https://own.example"))

    S.apply_studio_s3_settings!(FakeConfig.new("x", "https://own.example"), {}, strict: false, public_url_required: false)
    refute S.owns_connection?(FakeConfig.new("x", nil)), "after boot the boot's answer stands"

    S.apply_studio_s3_settings!(FakeConfig.new("x", nil), {}, strict: false, public_url_required: false)
    assert S.owns_connection?(FakeConfig.new("x", "https://filled.by.engine"))
  ensure
    S.reset_ownership!
  end

  def test_apply_keeps_a_public_url_the_app_set
    config = FakeConfig.new("turf-monster", nil, "us-east-2", nil, nil, "https://assets-dev.example")

    S.apply_studio_s3_settings!(config, {}, strict: false, public_url_required: true)
    assert_equal "https://r2-not-configured.invalid", config.s3_endpoint
    assert_equal "https://assets-dev.example", config.s3_public_url
  end

  def test_apply_raises_in_production_without_credentials
    config = FakeConfig.new("turf-monster", nil, "us-east-2")
    assert_raises(ArgumentError) { S.apply_studio_s3_settings!(config, {}, strict: true, public_url_required: false) }
  end

  # ---- on by default for an app that names its bucket ------------------------

  def test_enabled_only_for_an_app_that_names_its_bucket
    assert S.enabled?(prefix: "turf-monster", manage: true)
    refute S.enabled?(prefix: nil, manage: true)
    refute S.enabled?(prefix: " ", manage: true)
    refute S.enabled?(prefix: "turf-monster", manage: false)
    assert S.enabled?(prefix: "turf-monster", manage: nil), "only an explicit false opts out"
  end
end
