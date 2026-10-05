# frozen_string_literal: true

require "digest"
require "active_support/core_ext/object/blank"

module Studio
  # A SURVEY, defined in app code (docs/SURVEYS.md).
  #
  #   # config/surveys/first_game.rb — loaded by the engine on boot and reload
  #   Studio.define_survey "first-game" do
  #     title "How was your first game?"
  #     intro "Two minutes, six questions. It shapes what we build next."
  #     thank_you "Thanks — we read every answer."
  #     next_action label: "Play another game", url: "/play"
  #     allow_anonymous true
  #
  #     emoji_scale :overall, "How was your first game?", required: true
  #     rating :rules, "How clear were the rules?", low_label: "Lost", high_label: "Crystal clear"
  #     choice :found_us, "How did you find us?", options: ["Email", "A friend", "Search", "Other"]
  #     multi_choice :liked, "What did you enjoy?", options: ["The board", "The pace", "The art"]
  #     short_text :one_word, "Describe it in one word."
  #     long_text :anything_else, "Anything else?", help: "Bugs, ideas, complaints — all welcome."
  #   end
  #
  # The definition is the CURRENT shape of the survey, nothing more. A stored
  # answer carries its own question key, type and label snapshot (and the chosen
  # option's label), so editing or removing a question never rewrites what an
  # earlier respondent was asked. `version` defaults to a digest of the questions
  # and is stamped on every response.
  class Survey
    class DefinitionError < ArgumentError; end

    SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    KEY_FORMAT = /\A[a-z][a-z0-9_]{0,62}\z/
    TYPES = %i[emoji_scale rating choice multi_choice short_text long_text].freeze
    SCALE_TYPES = %i[emoji_scale rating].freeze
    SELECT_TYPES = %i[emoji_scale rating choice].freeze
    TEXT_TYPES = %i[short_text long_text].freeze

    EMOJI_FACES = ["\u{1F61E}", "\u{1F615}", "\u{1F610}", "\u{1F642}", "\u{1F60D}"].freeze
    DEFAULT_EMOJI_LABELS = ["Awful", "Not great", "Okay", "Good", "Loved it"].freeze
    TEXT_LIMITS = { short_text: 280, long_text: 5000 }.freeze

    Option = Struct.new(:value, :label, :face, keyword_init: true)

    # One question. Immutable once built.
    class Question
      attr_reader :key, :type, :label, :help, :options, :low_label, :high_label, :placeholder, :max_length

      def initialize(key:, type:, label:, required: false, help: nil, options: nil, labels: nil,
                     low_label: nil, high_label: nil, placeholder: nil, max_length: nil)
        @key = key.to_s
        @type = type.to_sym
        @label = label.to_s.strip
        @required = required == true
        @help = help.to_s.strip.presence
        @low_label = low_label.to_s.strip.presence
        @high_label = high_label.to_s.strip.presence
        @placeholder = placeholder.to_s.strip.presence
        validate_shape!(options, labels, max_length)
        @options = build_options(options, labels).freeze
        @max_length = text? ? Integer(max_length || TEXT_LIMITS.fetch(@type)) : nil
        freeze
      end

      def required? = @required
      def scale? = SCALE_TYPES.include?(type)
      def select? = SELECT_TYPES.include?(type)
      def multi? = type == :multi_choice
      def text? = TEXT_TYPES.include?(type)
      def numbered? = !text?

      def option(value)
        options.find { |o| o.value.to_s == value.to_s }
      end

      def blank_value?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?) || value.to_s.strip.empty?
      end

      # [normalized_value, error_message]. A blank input normalizes to nil, which
      # the response stores as "unanswered".
      def normalize(raw)
        raw = Array(raw).map(&:to_s).reject { |v| v.strip.empty? } if multi?
        return [nil, nil] if blank_value?(raw)

        case type
        when :emoji_scale, :rating
          int = Integer(raw.to_s.strip, exception: false)
          return [nil, "Pick one of the options."] unless int && option(int)

          [int, nil]
        when :choice
          opt = option(raw.to_s)
          opt ? [opt.value, nil] : [nil, "Pick one of the options."]
        when :multi_choice
          values = raw.uniq
          return [nil, "Pick from the listed options."] unless values.all? { |v| option(v) }

          # Keep the definition's order, not the click order.
          [options.map(&:value).select { |v| values.include?(v) }, nil]
        else
          text = raw.to_s.strip.gsub("\r\n", "\n")
          return [nil, "Keep it under #{max_length} characters."] if text.length > max_length

          [text, nil]
        end
      end

      # The human snapshot of an answer: the option label(s), or the text itself.
      def display(value)
        return nil if value.nil?
        return Array(value).map { |v| option(v)&.label || v.to_s } if multi?
        return value.to_s if text?

        option(value)&.label || value.to_s
      end

      def to_h
        { key: key, type: type, label: label, required: required?, help: help,
          options: options.map { |o| [o.value, o.label] }, low_label: low_label, high_label: high_label }
      end

      private

      def validate_shape!(options, labels, max_length)
        raise DefinitionError, "question key #{key.inspect} must match #{KEY_FORMAT.inspect}" unless key.match?(KEY_FORMAT)
        raise DefinitionError, "question #{key}: unknown type #{type.inspect} (one of #{TYPES.join(", ")})" unless TYPES.include?(type)
        raise DefinitionError, "question #{key}: label is required" if label.empty?

        if %i[choice multi_choice].include?(type)
          raise DefinitionError, "question #{key}: #{type} needs at least two options" if Array(options).size < 2
        elsif options
          raise DefinitionError, "question #{key}: options: is only for choice and multi_choice"
        end

        if labels && type != :emoji_scale
          raise DefinitionError, "question #{key}: labels: is only for emoji_scale"
        end
        if labels && Array(labels).size != 5
          raise DefinitionError, "question #{key}: emoji_scale takes exactly five labels"
        end
        if (low_label || high_label) && type != :rating
          raise DefinitionError, "question #{key}: low_label/high_label are only for rating"
        end
        if max_length && !text?
          raise DefinitionError, "question #{key}: max_length: is only for short_text and long_text"
        end
        return unless max_length && !(Integer(max_length, exception: false).to_i.between?(1, TEXT_LIMITS[:long_text]))

        raise DefinitionError, "question #{key}: max_length must be 1..#{TEXT_LIMITS[:long_text]}"
      end

      def build_options(options, labels)
        case type
        when :emoji_scale
          names = Array(labels || DEFAULT_EMOJI_LABELS).map { |l| l.to_s.strip }
          raise DefinitionError, "question #{key}: emoji labels cannot be blank" if names.any?(&:empty?)

          names.each_with_index.map { |name, i| Option.new(value: i + 1, label: name, face: EMOJI_FACES[i]) }
        when :rating
          (1..5).map { |n| Option.new(value: n, label: n.to_s) }
        when :choice, :multi_choice
          opts = Array(options).map { |o| coerce_option(o) }
          values = opts.map(&:value)
          raise DefinitionError, "question #{key}: option values must be unique" if values.uniq.size != values.size

          opts
        else
          []
        end
      end

      def coerce_option(raw)
        label, value =
          case raw
          when Hash then [raw[:label] || raw["label"], raw[:value] || raw["value"]]
          when Array then [raw[1], raw[0]]
          else [raw, nil]
          end
        label = label.to_s.strip
        raise DefinitionError, "question #{key}: option labels cannot be blank" if label.empty?

        value = (value.presence || label.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")).to_s
        raise DefinitionError, "question #{key}: option #{label.inspect} has no usable value" if value.empty?

        Option.new(value: value, label: label)
      end
    end

    # The block DSL. Every setter is a plain method so `title "x"` reads well.
    class Builder
      def initialize(slug)
        @attrs = { slug: slug.to_s, questions: [] }
      end

      def title(text) = @attrs[:title] = text
      def intro(text) = @attrs[:intro] = text
      def thank_you(text) = @attrs[:thank_you] = text
      def allow_anonymous(flag = true) = @attrs[:allow_anonymous] = flag
      def version(value) = @attrs[:version] = value

      def next_action(label:, url:)
        @attrs[:next_action] = { label: label.to_s.strip, url: url.to_s.strip }
      end

      TYPES.each do |type|
        define_method(type) do |key, label, **opts|
          @attrs[:questions] << Question.new(key: key, type: type, label: label, **opts)
        end
      end

      def build = Survey.new(**@attrs)
    end

    attr_reader :slug, :title, :intro, :thank_you, :next_action, :questions, :version

    def initialize(slug:, title: nil, intro: nil, thank_you: nil, next_action: nil, allow_anonymous: false,
                   version: nil, questions: [])
      @slug = slug.to_s
      @title = title.to_s.strip
      @intro = intro.to_s.strip.presence
      @thank_you = thank_you.to_s.strip.presence || "Thanks for taking the time."
      @next_action = next_action
      @allow_anonymous = allow_anonymous == true
      @questions = questions.dup.freeze
      validate!
      @version = (version.presence || fingerprint).to_s
      freeze
    end

    def allow_anonymous? = @allow_anonymous

    def question(key)
      questions.find { |q| q.key == key.to_s }
    end

    def keys = questions.map(&:key)
    def required_keys = questions.select(&:required?).map(&:key)

    private

    def validate!
      raise DefinitionError, "survey slug #{slug.inspect} must be lowercase words joined by hyphens" unless slug.match?(SLUG_FORMAT)
      raise DefinitionError, "survey #{slug}: title is required" if title.empty?
      raise DefinitionError, "survey #{slug}: needs at least one question" if questions.empty?

      dupes = keys.group_by(&:itself).select { |_, v| v.size > 1 }.keys
      raise DefinitionError, "survey #{slug}: duplicate question keys #{dupes.join(", ")}" if dupes.any?

      validate_next_action!
    end

    def validate_next_action!
      return if next_action.nil?

      label, url = next_action.values_at(:label, :url)
      raise DefinitionError, "survey #{slug}: next_action needs a label and a url" if label.to_s.empty? || url.to_s.empty?
      # A relative path or an http(s) URL — never javascript: or a protocol-relative //host.
      return if url.match?(%r{\A/(?!/)}) || url.match?(%r{\Ahttps?://}i)

      raise DefinitionError, "survey #{slug}: next_action url must be a /path or an http(s) URL"
    end

    def fingerprint
      Digest::SHA256.hexdigest(questions.map(&:to_h).inspect)[0, 12]
    end

    # --- registry --------------------------------------------------------------

    @registry = {}
    @mutex = Mutex.new

    class << self
      def define(slug, &block)
        raise DefinitionError, "define_survey needs a block" unless block

        builder = Builder.new(slug)
        builder.instance_eval(&block)
        survey = builder.build
        @mutex.synchronize { @registry[survey.slug] = survey }
        survey
      end

      def find(slug) = @registry[slug.to_s]

      def all = @registry.values.sort_by(&:slug)

      def reset! = @mutex.synchronize { @registry.clear }

      # Loads every *.rb under the app's survey directory. `load`, not `require`,
      # so a development reload picks up an edited definition.
      def load_definitions!(dir)
        return [] unless dir && File.directory?(dir.to_s)

        Dir[File.join(dir.to_s, "**", "*.rb")].sort.each { |path| load path }
      end
    end
  end
end
