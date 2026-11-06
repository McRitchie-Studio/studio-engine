# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/studio/tricks"

# [unit] The trick-name registry (config/studio_tricks.yml, Studio::Tricks). Alex
# McRitchie, 2026-11-06: "I really just need to have a good naming convention so I can
# convey an idea to my agents." A name is only useful if it is unique, follows the rule,
# points at something the engine really ships, and the glossary an agent reads
# (docs/TRICKS.md) says the same thing as the page.
class TricksRegistryTest < Minitest::Test
  T = Studio::Tricks
  ROOT = File.expand_path("../..", __dir__)
  CSS = Dir[File.join(ROOT, "app/assets/tailwind/studio_engine/*.css")].map { |f| File.read(f) }.join("\n")
  JS = Dir[File.join(ROOT, "app/javascript/**/*.js")].map { |f| File.read(f) }.join("\n")
  # The settings an app writes in its initializer, read from the real lib/studio.rb
  # (test_helper stands in a smaller Studio).
  SETTINGS = File.read(File.join(ROOT, "lib/studio.rb"))
  HELPERS = Dir[File.join(ROOT, "app/helpers/**/*.rb")].map { |f| File.read(f) }.join("\n")

  def every_trick
    T.all.flat_map { |t| [t, *t.variants] }
  end

  def test_names_are_unique_across_the_guide
    names = T.names.map(&:downcase)
    assert_equal names.uniq, names, "a repeated name: #{names.tally.select { |_, n| n > 1 }.keys.inspect}"
  end

  def test_a_name_is_one_or_two_title_case_words_and_a_variant_adds_a_lower_case_word
    T.all.each do |t|
      assert_match(/\A[A-Z][a-z]+( [A-Z][a-z]+)?\z/, t.name, "#{t.key}: the name rule")
      t.variants.each do |v|
        assert_match(/\A#{Regexp.escape(t.name)} · [a-z][a-z-]*( [a-z]+)?\z/, v.name, "#{t.key}: the variant rule")
      end
    end
  end

  def test_every_trick_has_a_group_a_token_and_a_one_line_note
    every_trick.each do |t|
      refute_empty t.group.to_s, "#{t.name}: group"
      refute_empty t.token.to_s, "#{t.name}: token"
      refute_includes t.token, "|", "#{t.name}: a pipe would break the doc's table"
      assert_operator t.note.split.size, :<=, 14, "#{t.name}: one short sentence: #{t.note.inspect}"
      refute_empty t.resolve, "#{t.name}: nothing to resolve"
    end
  end

  # Not CSS alone: a trick can be a class, a helper, a partial, a script call or a
  # setting, and each kind is looked for where the engine ships it.
  def test_every_token_resolves_to_something_the_engine_ships
    every_trick.each do |t|
      t.resolve.each do |ref|
        kind, name = ref.split(":", 2)
        found = case kind
                when "css"     then css_class?(name)
                when "helper"  then HELPERS.match?(/def (self\.)?#{Regexp.escape(name)}\b/)
                when "partial" then File.exist?(File.join(ROOT, "app/views", File.dirname(name), "_#{File.basename(name)}.html.erb"))
                when "js"      then JS.include?(name)
                when "config"  then SETTINGS.match?(/(mattr_(accessor|reader)|def self\.)\s*:?#{Regexp.escape(name)}\b/)
                else flunk "#{t.name}: unknown resolve kind #{kind.inspect}"
                end
        assert found, "#{t.name}: #{ref} is not in the engine"
      end
    end
  end

  # A class is a selector (.sheen) or a Tailwind @utility (btn-lg): both ship.
  def css_class?(name)
    CSS.match?(/\.#{Regexp.escape(name)}(?![\w-])/) || CSS.match?(/@utility #{Regexp.escape(name)} \{/)
  end

  def test_the_resolver_refuses_what_is_not_there
    refute css_class?("sheen--never"), "the css probe is not vacuous"
    refute HELPERS.match?(/def studio_never_a_helper\b/), "the helper probe is not vacuous"
    assert css_class?("sheen") && !css_class?("shee"), "a prefix is not a class"
    assert css_class?("btn-lg") && !css_class?("btn-l"), "nor a prefix of a utility"
  end

  # Every branded loader style has its own card, so the registry names each one.
  def test_every_loader_style_has_a_variant
    assert_equal Studio::Loader::STYLES.map(&:to_s), T.fetch("loader").variants.map(&:variant)
  end

  def test_the_agent_line_carries_the_name_the_token_and_the_variants
    assert_equal "Sheen — .sheen; Sheen · loop — .sheen--loop", T.agent_line("sheen")
    assert_equal "Sheen · loop — .sheen--loop", T.agent_line("sheen", "loop")
    assert_equal "Loader · weld bead", T.fetch("loader", "weld_bead").name
  end

  def test_an_unknown_trick_or_variant_raises
    assert_raises(T::UnknownTrick) { T.fetch("no_such_trick") }
    assert_raises(T::UnknownTrick) { T.fetch("sheen", "sideways") }
  end

  def test_the_glossary_matches_the_registry
    assert_equal T.markdown, File.read(T::DOC_PATH),
      "docs/TRICKS.md has drifted from config/studio_tricks.yml: run bin/tricks-doc"
    T.names.each { |name| assert_includes File.read(T::DOC_PATH), name }
  end
end
