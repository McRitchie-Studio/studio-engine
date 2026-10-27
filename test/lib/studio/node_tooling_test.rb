# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/node_tooling"
require "json"
require "rake"
require "rubygems"
require "tmpdir"

# [unit] Studio::NodeTooling: the engine's one Node tooling package.
#
# What these pin:
#   · the engine is its own first consumer, so it holds itself to the pins it
#     ships (.tool-versions, package.json engines, Playwright declared and locked);
#   · drift names every way a host differs, and stays quiet on a package the
#     host does not use;
#   · link! puts the package at node_modules/.studio-engine, and never deletes
#     a real directory to do it;
#   · the package ships in the gem and requires nothing a gem directory lacks.
class StudioNodeToolingTest < Minitest::Test
  ENGINE_ROOT = File.expand_path("../../..", __dir__)
  RAKE_FILE = File.join(ENGINE_ROOT, "lib/tasks/studio_node.rake")
  PINS = Studio::NodeTooling.versions

  def test_the_engine_matches_its_own_pins
    assert_equal [], Studio::NodeTooling.drift(ENGINE_ROOT)
  end

  def test_the_pins_name_node_22_and_exact_versions
    assert_equal "22", PINS["node"]
    PINS.except("node").each do |name, version|
      assert_match(/\A\d+\.\d+\.\d+\z/, version, "#{name} must be an exact version, not a range")
    end
  end

  def test_both_ci_node_steps_read_the_pin_file
    workflow = File.read(File.join(ENGINE_ROOT, ".github/workflows/engine-ci.yml"))
    steps = workflow.scan(/uses: actions\/setup-node@\S+\n\s+with:\n((?:\s{10}.*\n)+)/).flatten
    assert_equal 2, steps.length, "engine-ci.yml should set up Node in the suite and the browser lane"
    steps.each do |with|
      assert_match(/node-version-file: \.tool-versions/, with)
      refute_match(/node-version:/, with, "a literal node-version would drift from .tool-versions")
    end
  end

  def test_a_matching_host_has_no_drift
    in_host(tool_versions: "ruby 3.3.11\nnodejs 22\n") do |root|
      assert_equal [], Studio::NodeTooling.drift(root)
    end
  end

  def test_node_is_accepted_as_the_tool_name
    in_host(tool_versions: "node 22\n") { |root| assert_equal [], Studio::NodeTooling.drift(root) }
  end

  def test_a_missing_tool_versions_is_drift
    in_host(tool_versions: nil) do |root|
      assert_equal ['no .tool-versions; it should read "nodejs 22"'], Studio::NodeTooling.drift(root)
    end
  end

  def test_a_tool_versions_without_node_is_drift
    in_host(tool_versions: "ruby 3.3.11\n") do |root|
      assert_equal ['.tool-versions names no nodejs; it should read "nodejs 22"'], Studio::NodeTooling.drift(root)
    end
  end

  def test_the_wrong_node_major_is_drift
    in_host(tool_versions: "nodejs 20\n") do |root|
      assert_equal ['.tool-versions reads "nodejs 20"; it should read "nodejs 22"'], Studio::NodeTooling.drift(root)
    end
  end

  def test_the_wrong_engines_field_is_drift
    in_host(engines: "20.x") do |root|
      assert_equal ['package.json engines.node is "20.x"; the pin is "22.x"'], Studio::NodeTooling.drift(root)
    end
  end

  def test_a_range_is_drift_even_when_the_lock_matches
    in_host(declared: { "@playwright/test" => "^1.52.0" }) do |root|
      assert_equal ["package.json declares @playwright/test \"^1.52.0\"; the pin is \"#{PINS["@playwright/test"]}\""],
                   Studio::NodeTooling.drift(root)
    end
  end

  def test_a_lock_behind_the_pin_is_drift
    in_host(locked: { "@playwright/test" => "1.58.2" }) do |root|
      assert_equal ["package-lock.json locks @playwright/test at \"1.58.2\"; the pin is \"#{PINS["@playwright/test"]}\""],
                   Studio::NodeTooling.drift(root)
    end
  end

  def test_a_missing_lock_is_drift_for_a_declared_package
    in_host(lock: false) do |root|
      assert_equal ["package-lock.json locks @playwright/test at nil; the pin is \"#{PINS["@playwright/test"]}\""],
                   Studio::NodeTooling.drift(root)
    end
  end

  def test_a_runtime_dependency_is_held_to_the_pin_too
    in_host(declared: {}, runtime: { "axe-core" => "^4.11.0" }, locked: { "axe-core" => PINS["axe-core"] }) do |root|
      assert_equal ["package.json declares axe-core \"^4.11.0\"; the pin is \"#{PINS["axe-core"]}\""],
                   Studio::NodeTooling.drift(root)
    end
  end

  # A host that does not use axe-core is not made to install it.
  def test_an_undeclared_pinned_package_is_not_drift
    in_host(declared: { "@playwright/test" => PINS["@playwright/test"] }) do |root|
      refute PINS.except("node", "@playwright/test").empty?, "the control needs a pin this host leaves out"
      assert_equal [], Studio::NodeTooling.drift(root)
    end
  end

  # cyvasse and moms-app run node:test with no package.json; only Node is checked.
  def test_a_host_with_no_package_json_is_held_only_to_node
    in_host(package: false) { |root| assert_equal [], Studio::NodeTooling.drift(root) }
    in_host(package: false, tool_versions: "nodejs 20\n") do |root|
      assert_equal 1, Studio::NodeTooling.drift(root).length
    end
  end

  def test_link_points_node_modules_at_the_package
    Dir.mktmpdir do |root|
      path = Studio::NodeTooling.link!(root)
      assert_equal File.join(root, "node_modules/.studio-engine"), path.to_s
      assert path.symlink?
      assert_equal Studio::NodeTooling.root.to_s, File.readlink(path)
      assert File.file?(path.join("playwright_base.js")), "the link must resolve to the package's files"
      assert_equal path, Studio::NodeTooling.link!(root), "a second link is a no-op"
    end
  end

  def test_link_replaces_a_stale_link
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "node_modules"))
      File.symlink("/nowhere/studio-engine-0.1.0/lib/studio/node_tooling", File.join(root, "node_modules/.studio-engine"))
      path = Studio::NodeTooling.link!(root)
      assert_equal Studio::NodeTooling.root.to_s, File.readlink(path)
    end
  end

  def test_link_refuses_a_real_directory
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "node_modules/.studio-engine"))
      File.write(File.join(root, "node_modules/.studio-engine/keep.js"), "")
      error = assert_raises(ArgumentError) { Studio::NodeTooling.link!(root) }
      assert_match(/is not a symlink/, error.message)
      assert File.file?(File.join(root, "node_modules/.studio-engine/keep.js")), "link! must not delete it"
    end
  end

  def test_the_check_task_aborts_naming_each_problem
    in_host(tool_versions: "nodejs 20\n", engines: "20.x") do |root|
      error = assert_raises(SystemExit) { with_rails_root(root) { capture_io { run_task("studio:node:check") } } }
      refute error.success?
    end
    in_host(tool_versions: "nodejs 20\n") do |root|
      _out, err = capture_io do
        assert_raises(SystemExit) { with_rails_root(root) { run_task("studio:node:check") } }
      end
      assert_match(/drifts from the pins/, err)
      assert_match(/\.tool-versions reads "nodejs 20"/, err)
    end
  end

  def test_the_check_task_passes_a_matching_host
    in_host do |root|
      out, = capture_io { with_rails_root(root) { run_task("studio:node:check") } }
      assert_match(/matches the pins/, out)
    end
  end

  def test_the_link_task_links
    Dir.mktmpdir do |root|
      out, = capture_io { with_rails_root(root) { run_task("studio:node:link") } }
      assert_match(%r{node_modules/\.studio-engine ->}, out)
      assert File.symlink?(File.join(root, "node_modules/.studio-engine"))
    end
  end

  def test_the_package_ships_in_the_gem
    files = Dir.chdir(ENGINE_ROOT) { Gem::Specification.load(File.join(ENGINE_ROOT, "studio-engine.gemspec")).files }
    package = Dir.glob("lib/studio/node_tooling/**/*", base: ENGINE_ROOT).select { |f| File.file?(File.join(ENGINE_ROOT, f)) }
    assert_operator package.length, :>=, 6
    package.each { |file| assert_includes files, file }
    assert_includes files, "lib/tasks/studio_node.rake"
  end

  # Loaded from the gem's directory, which has no node_modules: a bare package
  # name would resolve nowhere on a host.
  def test_the_package_requires_only_builtins_and_siblings
    seen = []
    Dir.glob(File.join(Studio::NodeTooling.root, "**/*.{js,mjs}")).each do |path|
      source = File.read(path).gsub(%r{^\s*//.*$}, "")
      specifiers = source.scan(/(?:require\(|from\s+|import\(|register\()\s*["']([^"']+)["']/).flatten
      seen.concat(specifiers)
      specifiers.each do |specifier|
        assert specifier.start_with?("node:", "./", "../"),
               "#{File.basename(path)} loads #{specifier.inspect}, which a gem directory cannot resolve"
      end
    end
    # The scan reads what it should: the known loads are in what it saw.
    assert_includes seen, "node:fs"
    assert_includes seen, "./importmap_hooks.mjs"
  end

  private

  def in_host(tool_versions: "nodejs 22\n", engines: "22.x", package: true, lock: true,
              declared: { "@playwright/test" => PINS["@playwright/test"] }, runtime: {},
              locked: { "@playwright/test" => PINS["@playwright/test"] })
    Dir.mktmpdir do |root|
      File.write(File.join(root, ".tool-versions"), tool_versions) if tool_versions
      if package
        json = { "name" => "host", "private" => true, "engines" => { "node" => engines }, "devDependencies" => declared }
        json["dependencies"] = runtime unless runtime.empty?
        File.write(File.join(root, "package.json"), JSON.pretty_generate(json))
      end
      if package && lock
        packages = { "" => { "name" => "host" } }
        locked.each { |name, version| packages["node_modules/#{name}"] = { "version" => version } }
        File.write(File.join(root, "package-lock.json"), JSON.generate("lockfileVersion" => 3, "packages" => packages))
      end
      yield root
    end
  end

  # Points the tasks at `root` through host_root, so no Rails constant is ever
  # defined in this process (a stray `Rails` changes what other tests see).
  def with_rails_root(root)
    tooling = Studio::NodeTooling.singleton_class
    tooling.alias_method(:__host_root, :host_root)
    tooling.define_method(:host_root) { Pathname(root) }
    yield
  ensure
    tooling.alias_method(:host_root, :__host_root)
    tooling.remove_method(:__host_root)
  end

  def run_task(name)
    Rake.application = Rake::Application.new
    load RAKE_FILE
    Rake::Task[name].invoke
  ensure
    Rake.application = Rake::Application.new
  end
end
