# frozen_string_literal: true

require "yaml"

module Studio
  # The trick names on /admin/style (config/studio_tricks.yml). Alex McRitchie, 2026-11-06:
  # "I really just need to have a good naming convention so I can convey an idea to my
  # agents." Every specimen card reads its name, note and token from here, and
  # docs/TRICKS.md, the agent-facing glossary, is generated from the same file
  # (bin/tricks-doc), so the page and the doc cannot say different things.
  #
  #   Studio::Tricks.fetch("sheen")            # => the Sheen trick
  #   Studio::Tricks.fetch("sheen", "loop")    # => "Sheen · loop", its own card's trick
  #   Studio::Tricks.agent_line("sheen")       # => "Sheen — .sheen; Sheen · loop — .sheen--loop"
  module Tricks
    PATH = File.expand_path("../../config/studio_tricks.yml", __dir__)
    DOC_PATH = File.expand_path("../../docs/TRICKS.md", __dir__)
    SEPARATOR = " · "

    # One trick, or one variant of one (base is then its parent).
    Trick = Struct.new(:key, :variant, :name, :group, :token, :note, :resolve, :variants, :base,
                       keyword_init: true)

    class UnknownTrick < KeyError; end

    module_function

    # Every top-level trick, in file order (which is page order).
    def all
      @all ||= load_all
    end

    def reload!
      @all = nil
      all
    end

    def fetch(key, variant = nil)
      trick = all.find { |t| t.key == key.to_s } or
        raise UnknownTrick, "no trick #{key.inspect} in config/studio_tricks.yml"
      return trick if variant.nil?

      trick.variants.find { |v| v.variant == variant.to_s } or
        raise UnknownTrick, "trick #{key.inspect} has no variant #{variant.inspect}"
    end

    # Every name on the guide, variants included.
    def names
      all.flat_map { |t| [t.name, *t.variants.map(&:name)] }
    end

    # What the card's one Copy puts on the clipboard: the name and what to write, so it
    # can be pasted straight to an agent. A trick's line carries its variants; a
    # variant's line is its own.
    def agent_line(key, variant = nil)
      trick = fetch(key, variant)
      [trick, *trick.variants].map { |t| "#{t.name} — #{t.token}" }.join("; ")
    end

    def markdown
      lines = []
      lines << "# Tricks"
      lines << ""
      lines << "<!-- Generated from config/studio_tricks.yml by bin/tricks-doc. Edit the YAML, then run it. -->"
      lines << ""
      lines << "The names of the specimens on `/admin/style`. Say the name and an agent writes the"
      lines << "token: \"add a Sheen\" means `.sheen` on a `.btn`; \"make it Sheen · loop\" adds"
      lines << "`.sheen--loop`."
      lines << ""
      lines << "A name is one or two Title-case words. A variant is the name, a middle dot and a"
      lines << "lower-case word (`Border Glow · clear`). Every name is unique across the guide."
      all.group_by(&:group).each do |group, tricks|
        lines << ""
        lines << "## #{group}"
        lines << ""
        lines << "| Name | Write | What it does |"
        lines << "|------|-------|--------------|"
        tricks.each do |trick|
          lines << row("**#{trick.name}**", trick)
          trick.variants.each { |v| lines << row(v.name, v) }
        end
      end
      lines << ""
      lines.join("\n")
    end

    def row(label, trick)
      "| #{label} | `#{trick.token}` | #{trick.note} |"
    end

    def load_all
      YAML.safe_load_file(PATH).map do |key, entry|
        base = build(key: key, name: entry.fetch("name"), group: entry.fetch("group"), entry: entry)
        base.variants = (entry["variants"] || {}).map do |word, v|
          build(key: key, variant: word, name: "#{base.name}#{SEPARATOR}#{word.tr('_', ' ')}",
                group: base.group, entry: v, base: base)
        end
        base
      end.freeze
    end

    def build(key:, name:, group:, entry:, variant: nil, base: nil)
      Trick.new(key: key, variant: variant, name: name, group: group,
                token: entry.fetch("token"), note: entry.fetch("note"),
                resolve: Array(entry["resolve"]), variants: [], base: base)
    end

    private_class_method :row, :load_all, :build
  end
end
