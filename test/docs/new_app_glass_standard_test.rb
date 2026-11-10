# frozen_string_literal: true

require "test_helper"

# [unit] Glass is the standard for a new app (Alex McRitchie, 2026-11-09). The new-app
# initializer in docs/NEW_APP_SETUP.md is the template every new app copies, so this test
# RUNS that block against a recording config and reads what it set. A commented-out or
# misspelt line fails here. The layout block must write data-surface-style on <html>,
# because Studio.surface_style alone does not reach the CSS.
#
# THE OTHER HALF: the engine default stays :default. Existing apps that left glass out on
# purpose (moms-app, rantly) must not move when they bump the gem.
class NewAppGlassStandardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DOC = File.read(File.join(ROOT, "docs/NEW_APP_SETUP.md")).freeze

  # Records every `config.x = value` the template makes.
  class Recorder
    attr_reader :set

    def initialize = @set = {}

    def method_missing(name, *args)
      return super unless name.end_with?("=") && args.size == 1

      @set[name.to_s.chomp("=").to_sym] = args.first
    end

    def respond_to_missing?(name, include_private = false) = name.end_with?("=") || super
  end

  # Stands in for Studio inside the template: configure yields the recorder, and any
  # helper the template calls (Studio.mailer_from_for_transport) answers nil.
  class FakeStudio
    def initialize(recorder) = @recorder = recorder
    def configure = yield(@recorder)
    def method_missing(*) = nil
    def respond_to_missing?(*) = true
  end

  def block(heading, lang)
    section = DOC[/^### `#{Regexp.escape(heading)}`\n(.*?)(?=^### |^## )/m, 1]
    refute_nil section, "no ### `#{heading}` section in docs/NEW_APP_SETUP.md"
    section[/^```#{lang}\n(.*?)^```/m, 1] || flunk("no ```#{lang} block under #{heading}")
  end

  def run_template
    recorder = Recorder.new
    sandbox = Module.new
    sandbox.const_set(:Studio, FakeStudio.new(recorder))
    sandbox.module_eval(block("config/initializers/studio.rb", "ruby"), "NEW_APP_SETUP.md")
    recorder.set
  end

  def test_the_initializer_template_turns_on_glass_surfaces_and_the_glass_sidebar
    set = run_template

    assert_equal :glass, set[:surface_style], "the template must set config.surface_style = :glass"
    assert_equal :glass, set[:sidebar_style], "the template must set config.sidebar_style = :glass"
    # The engine's own validation takes the value, so the template boots.
    assert_equal :glass, Studio::SidebarSections.style!(set[:sidebar_style])
  end

  def test_the_template_is_really_run
    set = run_template

    assert_equal "X App", set[:app_name], "the recorder saw the template's first line"
  end

  def test_the_layout_template_writes_the_surface_style_on_html
    layout = block("app/views/layouts/application.html.erb", "erb")

    assert_match(/^<html[^>]*\bdata-surface-style="<%= Studio\.surface_style %>"/, layout)
  end

  # The brand-colour paragraph names the override layer and the dark trap. A token in
  # @layer components loses to the engine's @layer utilities default and nothing reports
  # it; e2e/glass_surface_tokens.spec.js shows that in a browser.
  def glass_colours
    DOC[/^\*\*Glass in the brand's colours\.\*\*(.*?)^```\n/m, 1] ||
      flunk("no **Glass in the brand's colours.** paragraph with a css example in docs/NEW_APP_SETUP.md")
  end

  def test_the_glass_colours_paragraph_names_the_layer_and_the_dark_trap
    text = glass_colours.gsub(/\s+/, " ")

    assert_includes text, "**Outside any layer.**"
    assert_includes text, "Never put them in `@layer components`"
    assert_includes text, "A token set only on `:root` also applies in the dark theme"
  end

  def test_the_css_example_sets_every_root_glass_token_the_engine_declares
    css = File.read(File.join(ROOT, "app/assets/tailwind/studio_engine/engine.css"))
    declared = css.scan(/^\s*:root \{[^}]*\}/).join.scan(/(--glass-(?:sidebar|surface)-[a-z-]+):/).flatten.uniq
    example = glass_colours[/```css\n(.*)/m, 1]

    assert_operator declared.size, :>=, 6, "the engine declares the sidebar's four and the surfaces' two"
    declared.each { |token| assert_includes example, "#{token}:", "the § 9 example must set #{token}" }
  end

  def test_the_engine_default_does_not_move_for_existing_apps
    source = File.read(File.join(ROOT, "lib/studio.rb"))

    assert_match(/^\s*mattr_reader :surface_style, default: :default$/, source)
    assert_match(/^\s*mattr_reader :sidebar_style, default: :default$/, source)
  end
end
