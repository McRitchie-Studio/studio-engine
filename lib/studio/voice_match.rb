# frozen_string_literal: true

require "json"

# Who is speaking: compares one take's speaker embedding with the voice
# embeddings saved on users' own records (the voice row on /profile, opt-in with
# Studio.voice_profile). Pure arithmetic on arrays of floats, with no Rails
# dependency, so the threshold logic is unit-tested without a browser, a model or
# a database.
#
# THE EMBEDDINGS COME FROM THE BROWSER. The profile page records three short
# phrases, turns each take into a vector on the person's own device
# (app/javascript/studio/voice_profile.js), drops the audio, and posts only the
# vectors. The server averages them here and stores one vector on the user. No
# audio is ever uploaded for this.
#
# Ported from Voicebox's SpeakerMatch (McRitchie-Studio/voicebox#10), where the
# embedder, the threshold and the averaging were measured.
module Studio
  module VoiceMatch
    # The speaker embedders the browser may run, by name. `id` is what is stored
    # on the user beside the vector (users.voice_embedding_model): vectors from
    # two models, or from two revisions of one model, are not comparable, so the
    # matcher only ever compares a take with users whose id is the same.
    #
    # "wespeaker" is WeSpeaker's ResNet34 speaker model (trained on VoxCeleb),
    # int8-quantized, run by transformers.js on onnxruntime-web. The model is
    # about 6.7 MB and the runtime about 4.3 MB; the browser caches both after the
    # first load. Its revision is pinned so THRESHOLD always describes the vectors
    # it was tuned on. Changing the revision is changing the id, and every saved
    # voice stops matching until its owner re-records.
    #
    # "fake" is for tests only: a deterministic vector seeded by a voice name the
    # test sets on the page (window.studioFakeVoice), because Chrome's fake
    # microphone cannot play chosen audio.
    TRANSFORMERS_VERSION = "3.7.6"

    # Where the browser imports transformers.js from, by full URL. NOT an
    # importmap pin: every pin a host draws must be a fingerprinted local asset
    # (the hub's AssetUrlsTest), and a ~1 MB runtime that fetches its own
    # onnxruntime WebAssembly from the same jsDelivr path anyway gains nothing
    # from being vendored. A host's CSP names this package path.
    TRANSFORMERS_URL =
      "https://cdn.jsdelivr.net/npm/@huggingface/transformers@#{TRANSFORMERS_VERSION}/dist/transformers.min.js"

    EMBEDDERS = {
      "wespeaker" => {
        "id" => "wespeaker-voxceleb-resnet34-LM@6a61a18",
        "size" => 256,
        "model" => "onnx-community/wespeaker-voxceleb-resnet34-LM",
        "revision" => "6a61a1833ff2583aabeba044f5c8221f00b67ceb",
        "dtype" => "q8",
        "runtime" => TRANSFORMERS_URL
      }.freeze,
      "fake" => {
        "id" => "fake-256",
        "size" => 256
      }.freeze
    }.freeze

    # The columns the voice lives in on the host's users table, installed by the
    # engine migration add_voice_profile_to_users.
    USER_COLUMNS = %i[voice_embedding voice_embedding_model voice_embedding_updated_at].freeze

    # What the setup asks the person to read: three short, phonetically varied
    # sentences of about four seconds each. TAKES is their count, and the server
    # refuses a save with any other number of vectors.
    PHRASES = [
      "The quick brown fox jumps over the lazy dog.",
      "I'd like a cup of coffee and a slice of toast, please.",
      "My voice is my own, and today is a good day to talk."
    ].freeze

    TAKES = PHRASES.size

    # The cosine similarity a take must reach to be named. Measured in Voicebox
    # (2026-10-29) on the wespeaker embedder, enrolling five synthetic voices from
    # three phrases each and probing with a fourth: same voice 0.85 - 0.91,
    # different voice 0.04 - 0.53 (the closest pair two adult women). 0.6 sits
    # above every different-voice score and well under every same-voice one.
    THRESHOLD = 0.6

    # user: the closest user at or above the threshold, else nil. score: that
    # closest similarity, or nil when there was nothing to compare.
    Result = Struct.new(:user, :score, keyword_init: true) do
      def unknown? = user.nil?
    end

    NONE = Result.new(user: nil, score: nil).freeze

    module_function

    # The settings the page hands the browser for one embedder.
    def browser_config(name)
      config = EMBEDDERS.fetch(name.to_s)
      { "name" => name.to_s }.merge(config)
    end

    def embedder!(name)
      EMBEDDERS.fetch(name.to_s) do
        raise ArgumentError, "Studio.voice_embedder must be one of #{EMBEDDERS.keys.join(', ')} (got #{name.inspect})"
      end
    end

    def model_id(name) = embedder!(name).fetch("id")

    def size(name) = embedder!(name).fetch("size")

    # The closest user to `embedding` among `among`, or nil when nobody reaches
    # the threshold. Only users whose saved vector came from `model` are
    # compared. `among` is anything enumerable of users; an ActiveRecord scope is
    # narrowed to that model in SQL first.
    def identify(embedding, among:, model:, threshold: THRESHOLD)
      match(embedding, among: among, model: model, threshold: threshold).user
    end

    # identify, with the score: a caller that wants to say "someone new" needs to
    # tell "nobody close" (a score below the threshold) from "nothing to compare".
    def match(embedding, among:, model:, threshold: THRESHOLD)
      probe = vector(embedding)
      return NONE if probe.nil? || model.to_s.empty?

      best = nil
      best_score = nil
      candidates(among, model).each do |user|
        next unless user.respond_to?(:voice_embedding_model) && user.voice_embedding_model.to_s == model.to_s

        saved = vector(user.voice_embedding)
        next if saved.nil? || saved.size != probe.size

        score = cosine(probe, saved)
        next if score.nil?

        if best_score.nil? || score > best_score
          best = user
          best_score = score
        end
      end
      return NONE if best_score.nil?

      Result.new(user: best_score >= threshold ? best : nil, score: best_score.round(4))
    end

    # Cosine similarity, -1..1; nil when the sizes differ or either vector has
    # no length.
    def cosine(a, b)
      return nil unless a.size == b.size

      dot = 0.0
      norm_a = 0.0
      norm_b = 0.0
      a.each_with_index do |x, i|
        y = b[i]
        dot += x * y
        norm_a += x * x
        norm_b += y * y
      end
      return nil if norm_a.zero? || norm_b.zero?

      dot / Math.sqrt(norm_a * norm_b)
    end

    # One profile vector from the setup takes: each take scaled to unit length,
    # so a loud phrase does not outweigh a quiet one, then averaged and scaled to
    # unit length again. nil when no take has any length (silence embeds to
    # zeros), or the takes disagree on size.
    def average(vectors)
      units = Array(vectors).map { |v| normalize(v) }.compact
      return nil if units.empty?
      return nil unless units.all? { |u| u.size == units.first.size }

      sum = Array.new(units.first.size, 0.0)
      units.each { |u| u.each_with_index { |x, i| sum[i] += x } }
      normalize(sum)
    end

    def normalize(vector)
      return nil if vector.nil? || vector.empty?

      norm = Math.sqrt(vector.sum { |x| x * x })
      return nil if norm.zero? || !norm.finite?

      vector.map { |x| x / norm }
    end

    # A vector the browser sent, as floats, or nil when it is not `size` finite
    # numbers. Accepts a JSON string or an already-parsed array.
    def parse(raw, size:)
      values = raw.is_a?(String) ? JSON.parse(raw) : raw
      return nil unless values.is_a?(Array) && values.size == size
      return nil unless values.all? { |x| x.is_a?(Numeric) && x.to_f.finite? }

      values.map(&:to_f)
    rescue JSON::ParserError
      nil
    end

    # The setup's takes, validated: exactly TAKES vectors of `size` finite
    # numbers, each with some length. Returns the averaged unit vector, or nil.
    def enrol(raw_takes, size:)
      takes = raw_takes.is_a?(String) ? JSON.parse(raw_takes) : raw_takes
      return nil unless takes.is_a?(Array) && takes.size == TAKES

      vectors = takes.map { |take| parse(take, size: size) }
      return nil if vectors.any?(&:nil?)
      return nil if vectors.any? { |v| normalize(v).nil? }

      average(vectors)
    rescue JSON::ParserError
      nil
    end

    # A stored embedding (jsonb array, or a JSON string on an adapter without
    # json columns) as floats, or nil.
    def vector(raw)
      values = raw.is_a?(String) ? JSON.parse(raw) : raw
      return nil unless values.is_a?(Array) && !values.empty?
      return nil unless values.all? { |x| x.is_a?(Numeric) && x.to_f.finite? }

      values.map(&:to_f)
    rescue JSON::ParserError
      nil
    end

    def candidates(among, model)
      return Array(among) unless among.respond_to?(:where)

      # A scope or the model class itself. Narrowed in SQL only when the table
      # has the column; the per-user check in #match holds either way.
      klass = among.respond_to?(:klass) ? among.klass : among
      if klass.respond_to?(:column_names) && klass.column_names.include?("voice_embedding_model")
        among.where(voice_embedding_model: model.to_s)
      else
        among
      end
    end
  end
end
