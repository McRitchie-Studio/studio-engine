# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "tmpdir"

# [integration] A host's `@import "../builds/tailwind/studio_engine";` resolves
# to host.css, through tailwindcss-rails' own engines contract.
#
# Runs the REAL Tailwindcss::Engines.bundle (what `bin/rails tailwindcss:engines`,
# :build, :watch and assets:precompile run) in the booted dummy app, against a
# scratch Rails.root, and reads the entry it leaves. The control calls the
# unwrapped bundle and shows it would have imported the narrow engine.css,
# which carries no @source scan and no motion layer.
class TailwindEntryTest < ActiveSupport::TestCase
  ENTRY = Studio::TailwindEntry::ENTRY

  # Rails.root pointed at a scratch directory for the call, then restored.
  def bundle_into(dir, &call)
    original = Rails.method(:root)
    Rails.define_singleton_method(:root) { Pathname(dir) }
    begin
      call ? call.call : Tailwindcss::Engines.bundle
    ensure
      Rails.define_singleton_method(:root, original)
    end
    File.read(File.join(dir, ENTRY))
  end

  test "Rails.root is restored after a scratch bundle" do
    before = Rails.root
    Dir.mktmpdir("studio-entry") { |dir| bundle_into(dir) }
    assert_equal before, Rails.root
  end

  test "the engine initializer wrapped the engines contract" do
    assert_includes Tailwindcss::Engines.singleton_class.ancestors, Studio::TailwindEntry::Bundle
    assert Studio::TailwindEntry.install!, "install! must stay idempotent"
    assert_equal 1, Tailwindcss::Engines.singleton_class.ancestors.count(Studio::TailwindEntry::Bundle)
  end

  test "the generated entry imports host.css by the gem's absolute path" do
    Dir.mktmpdir("studio-entry") do |dir|
      entry = bundle_into(dir)
      host = Studio::Engine.root.join(Studio::TailwindEntry::HOST_CSS)

      assert_includes entry, %(@import "#{host}";)
      refute_includes entry, "engine.css"
      assert File.file?(host), "the entry points at a file the gem does not ship"
    end
  end

  test "control: the contract alone imports the narrow engine.css" do
    Dir.mktmpdir("studio-entry") do |dir|
      unwrapped = Tailwindcss::Engines.singleton_class.instance_method(:bundle).super_method
      entry = bundle_into(dir) { unwrapped.bind_call(Tailwindcss::Engines) }

      assert_includes entry, Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css").to_s
    end
  end

  test "write! leaves an app alone when the contract wrote no entry" do
    Dir.mktmpdir("studio-entry") do |dir|
      refute Studio::TailwindEntry.write!(app_root: dir, engine_root: Studio::Engine.root)
      refute File.exist?(File.join(dir, ENTRY))
    end
  end
end
