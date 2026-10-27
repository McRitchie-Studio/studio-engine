# frozen_string_literal: true

require "test_helper"

# [unit] A module the engine head loads BY URL imports no bare specifier.
#
# javascript_include_tag "x", type: "module" also sends `Link: <x>; rel=modulepreload`
# as a response header (config.action_view.preload_links_header, on by default in
# every host). The browser acts on that header before it parses the body, so it
# fetches the module, and resolves its static imports, before the head's import map
# exists. A bare specifier there ("canvas-confetti") resolves against no map and the
# failure is cached with the module, so the tag below the map rethrows it:
# `TypeError: Failed to resolve module specifier`. That shipped in studio-engine
# 0.115.1.rc1 and failed 11 hub e2e specs (task confetti-resolves-on-hub); a module
# with bare imports takes javascript_import_module_tag, which sends no header.
#
# This reads every engine view, finds each javascript_include_tag with type "module",
# and scans the module's source for a static import or re-export of a specifier that
# is not a URL or a relative path. A dynamic import() resolves when it is called,
# after the map, so it is allowed.
class HeadUrlModulesImportNoBareSpecifierTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  INCLUDE_TAG = /javascript_include_tag\s*\(?\s*["']([^"']+)["']([^%]*)%>/
  STATIC_IMPORT = /^\s*(?:import\s+(?:[\w*{}\s,$]+\s+from\s+)?|export\s+(?:\*|\{[^}]*\})\s+from\s+)["']([^"']+)["']/

  def self.url_modules
    Dir[File.join(ROOT, "app/views/**/*.erb")].flat_map do |view|
      File.read(view).scan(INCLUDE_TAG).filter_map do |source, rest|
        source if rest.match?(/type:\s*["':]?module/)
      end
    end.uniq.sort
  end

  def self.module_file(source)
    logical = source.end_with?(".js") ? source : "#{source}.js"
    %w[app/javascript app/assets/javascripts]
      .map { |dir| File.join(ROOT, dir, logical) }
      .find { |path| File.file?(path) }
  end

  def self.bare_static_imports(js)
    code = js.gsub(%r{/\*.*?\*/}m, "").gsub(%r{^\s*//.*$}, "")
    code.scan(STATIC_IMPORT).flatten.reject { |spec| spec.match?(%r{\A(?:/|\./|\.\./|[a-z][a-z0-9+.-]*:)}i) }
  end

  def test_the_head_loads_modules_by_url
    refute_empty self.class.url_modules, "found no module loaded by URL, so the rule below checks nothing"
  end

  def test_no_module_loaded_by_url_imports_a_bare_specifier
    self.class.url_modules.each do |source|
      file = self.class.module_file(source)
      refute_nil file, "#{source} names no engine file"
      bare = self.class.bare_static_imports(File.read(file))
      assert_empty bare,
        "#{source} loads by URL (a Link modulepreload, fetched before the import map) yet imports #{bare.inspect}; use javascript_import_module_tag"
    end
  end

  # The scanner itself bites: the confetti module's own import is what it must catch.
  def test_the_scanner_finds_the_confetti_import
    assert_equal ["canvas-confetti"], self.class.bare_static_imports(%(import "canvas-confetti"\nconst a = 1))
    assert_equal ["x"], self.class.bare_static_imports(%(import { a, b } from "x"))
    assert_equal ["y"], self.class.bare_static_imports(%(export * from "y"))
    assert_empty self.class.bare_static_imports(%(import "./local.js"\nimport z from "/assets/z.js"\nconst m = await import("lazy")))
    assert_empty self.class.bare_static_imports(%(// import "commented"\n/* import "block" */))
  end
end
