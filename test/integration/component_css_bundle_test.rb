# frozen_string_literal: true

# Boots studio-engine inside the real Rails dummy app and proves the component
# stylesheet is IMPORTABLE by consumers exactly the way tailwindcss-rails
# delivers engine CSS: `Tailwindcss::Engines.bundle` (run automatically before
# every tailwindcss:build / tailwindcss:watch) discovers any Rails engine with
# an `app/assets/tailwind/<engine_name>/engine.css` and generates the host-app
# entry point `app/assets/builds/tailwind/<engine_name>.css` that the consumer
# @imports from application.css. If the engine_name or the file path ever
# drift, consumers' one-line adoption breaks — this test pins both.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "tailwindcss-rails"

class ComponentCssBundleTest < ActiveSupport::TestCase
  GENERATED = Rails.root.join("app/assets/builds")

  teardown do
    FileUtils.rm_rf(GENERATED)
  end

  test "engine ships the stylesheet at the tailwindcss-rails engines contract path" do
    assert_equal "studio_engine", Studio::Engine.engine_name,
      "engine_name drift breaks consumers' @import \"../builds/tailwind/studio_engine\" line"

    contract_path = Studio::Engine.root.join(
      "app/assets/tailwind/#{Studio::Engine.engine_name}/engine.css"
    )
    assert File.exist?(contract_path), "expected #{contract_path}"
  end

  test "Tailwindcss::Engines.bundle generates the consumer entry point for the engine" do
    Tailwindcss::Engines.bundle

    entry = Rails.root.join("app/assets/builds/tailwind/studio_engine.css")
    assert File.exist?(entry),
      "tailwindcss-rails did not generate the studio_engine entry point"

    # The entry imports host.css, which imports engine.css first
    # (Studio::TailwindEntry; test/integration/tailwind_entry_test.rb).
    host_css = Studio::Engine.root.join("app/assets/tailwind/studio_engine/host.css")
    assert_includes File.read(entry), %(@import "#{host_css}";),
      "generated entry point must @import the engine's host entry"
    assert_match(/^@import "\.\/engine\.css";/, File.read(host_css),
      "host.css must bring the engine's component stylesheet")
  end
end
