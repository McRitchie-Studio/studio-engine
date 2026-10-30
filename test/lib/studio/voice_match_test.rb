# frozen_string_literal: true

require "test_helper"

# [unit] Studio::VoiceMatch (lib/studio/voice_match.rb): who is speaking, from
# one embedding, among users' saved voices. Pure arithmetic, so every rule is
# pinned here without a browser, a model or a database:
#
#   1. identify answers the CLOSEST user at or above THRESHOLD, else nil.
#   2. Only users whose voice came from the same model are compared.
#   3. Averaging gives each take equal weight and a unit-length result.
#   4. A save is exactly TAKES vectors of the model's size, finite and non-zero.
class VoiceMatchTest < Minitest::Test
  VM = Studio::VoiceMatch
  MODEL = VM.model_id("wespeaker")

  FakeUser = Struct.new(:name, :voice_embedding, :voice_embedding_model)

  # A unit vector along axis i, plus a little of axis j: lets a test place a
  # voice at a known cosine from another.
  def axis(i, size = 4)
    Array.new(size, 0.0).tap { |v| v[i] = 1.0 }
  end

  # A vector whose cosine with axis(0) is exactly `c`.
  def at_cosine(c, size = 4)
    Array.new(size, 0.0).tap do |v|
      v[0] = c
      v[1] = Math.sqrt(1 - c * c)
    end
  end

  def user(name, embedding, model = MODEL) = FakeUser.new(name, embedding, model)

  # --- identify ---------------------------------------------------------------

  def test_identify_names_the_closest_user_above_the_threshold
    near = user("near", at_cosine(0.9))
    nearer = user("nearer", at_cosine(0.95))
    far = user("far", axis(2))

    assert_equal nearer, VM.identify(axis(0), among: [near, far, nearer], model: MODEL)
  end

  def test_identify_is_nil_when_nobody_reaches_the_threshold
    below = user("below", at_cosine(0.59))

    assert_nil VM.identify(axis(0), among: [below], model: MODEL)
    result = VM.match(axis(0), among: [below], model: MODEL)
    assert result.unknown?
    assert_in_delta 0.59, result.score, 1e-4, "the score is kept, so a caller can say 'someone new'"
  end

  def test_the_threshold_is_inclusive
    exactly = user("exactly", at_cosine(VM::THRESHOLD))

    assert_equal exactly, VM.identify(axis(0), among: [exactly], model: MODEL)
  end

  def test_the_threshold_is_point_six
    assert_equal 0.6, VM::THRESHOLD
  end

  def test_a_custom_threshold_is_honoured
    loose = user("loose", at_cosine(0.4))

    assert_equal loose, VM.identify(axis(0), among: [loose], model: MODEL, threshold: 0.3)
    assert_nil VM.identify(axis(0), among: [loose], model: MODEL)
  end

  def test_users_from_another_model_are_never_compared
    same_voice_old_model = user("old", axis(0), "wespeaker@older-revision")

    assert_nil VM.identify(axis(0), among: [same_voice_old_model], model: MODEL)
    assert_equal VM::NONE, VM.match(axis(0), among: [same_voice_old_model], model: MODEL),
                 "nothing comparable is not the same as nobody close"
  end

  def test_users_without_a_voice_or_with_a_wrong_size_are_skipped
    none = user("none", nil)
    short = user("short", [1.0, 0.0])
    good = user("good", at_cosine(0.8))

    assert_equal good, VM.identify(axis(0), among: [none, short, good], model: MODEL)
  end

  def test_a_stored_json_string_is_read
    stringly = user("stringly", axis(0).to_json)

    assert_equal stringly, VM.identify(axis(0), among: [stringly], model: MODEL)
  end

  def test_a_blank_or_garbage_probe_matches_nobody
    someone = user("someone", axis(0))

    [nil, [], "not json", [0.0, 0.0, 0.0, 0.0], ["a", "b", "c", "d"]].each do |probe|
      assert_nil VM.identify(probe, among: [someone], model: MODEL), "probe #{probe.inspect}"
    end
    assert_nil VM.identify(axis(0), among: [someone], model: ""), "no model, no comparison"
  end

  def test_a_scope_is_narrowed_to_the_model_in_sql
    scope = Object.new
    klass = Object.new
    klass.define_singleton_method(:column_names) { %w[id voice_embedding voice_embedding_model] }
    narrowed_with = nil
    match = user("match", axis(0))
    scope.define_singleton_method(:klass) { klass }
    scope.define_singleton_method(:where) do |conditions|
      narrowed_with = conditions
      [match]
    end

    assert_equal match, VM.identify(axis(0), among: scope, model: MODEL)
    assert_equal({ voice_embedding_model: MODEL }, narrowed_with)
  end

  # --- cosine, average, normalize ------------------------------------------------

  def test_cosine
    assert_in_delta 1.0, VM.cosine([1, 2, 3], [2, 4, 6]), 1e-12
    assert_in_delta 0.0, VM.cosine([1, 0], [0, 1]), 1e-12
    assert_in_delta(-1.0, VM.cosine([1, 0], [-1, 0]), 1e-12)
    assert_nil VM.cosine([1, 0], [1, 0, 0]), "sizes must agree"
    assert_nil VM.cosine([0, 0], [1, 0]), "a zero vector has no direction"
  end

  def test_average_weights_each_take_equally_and_is_unit_length
    loud = [10.0, 0.0]
    quiet = [0.0, 0.1]
    avg = VM.average([loud, quiet])

    assert_in_delta avg[0], avg[1], 1e-12, "a loud take must not outweigh a quiet one"
    assert_in_delta 1.0, Math.sqrt(avg.sum { |x| x * x }), 1e-12
  end

  def test_average_refuses_nothing_usable
    assert_nil VM.average([])
    assert_nil VM.average([[0.0, 0.0]])
    assert_nil VM.average([[1.0, 0.0], [1.0, 0.0, 0.0]]), "takes that disagree on size"
  end

  # --- enrol: what a save may carry ----------------------------------------------

  def takes(n = VM::TAKES, size: 4) = Array.new(n) { |i| Array.new(size) { |j| (i + j + 1).to_f } }

  def test_enrol_averages_exactly_three_takes
    assert_equal 3, VM::TAKES
    assert_equal VM::PHRASES.size, VM::TAKES
    vector = VM.enrol(takes, size: 4)

    assert_equal 4, vector.size
    assert_in_delta 1.0, Math.sqrt(vector.sum { |x| x * x }), 1e-12
    assert_equal vector, VM.enrol(takes.to_json, size: 4), "a JSON string is the same save"
  end

  def test_enrol_refuses_the_wrong_number_of_takes
    assert_nil VM.enrol(takes(2), size: 4)
    assert_nil VM.enrol(takes(4), size: 4)
    assert_nil VM.enrol(nil, size: 4)
    assert_nil VM.enrol("not json", size: 4)
  end

  def test_enrol_refuses_a_take_of_the_wrong_size_or_not_finite
    bad_size = takes.tap { |t| t[1] = [1.0, 2.0] }
    not_finite = takes.tap { |t| t[2][0] = Float::NAN }
    not_numbers = takes.tap { |t| t[0] = %w[a b c d] }

    assert_nil VM.enrol(bad_size, size: 4)
    assert_nil VM.enrol(not_finite, size: 4)
    assert_nil VM.enrol(not_numbers, size: 4)
  end

  # Silence the browser let through embeds to zeros, and names nobody.
  def test_enrol_refuses_a_silent_take
    silent = takes.tap { |t| t[1] = [0.0, 0.0, 0.0, 0.0] }

    assert_nil VM.enrol(silent, size: 4)
  end

  # --- the embedders --------------------------------------------------------------

  def test_the_real_embedder_is_pinned
    config = VM.browser_config("wespeaker")

    assert_equal "wespeaker", config["name"]
    assert_equal 256, config["size"]
    assert_equal "onnx-community/wespeaker-voxceleb-resnet34-LM", config["model"]
    assert_equal "6a61a1833ff2583aabeba044f5c8221f00b67ceb", config["revision"]
    assert_equal "q8", config["dtype"]
    assert_includes config["id"], config["revision"][0, 7], "the id changes when the revision does"
  end

  def test_the_fake_and_real_ids_differ
    refute_equal VM.model_id("wespeaker"), VM.model_id("fake"),
                 "a test vector must never be comparable with a real one"
  end

  def test_an_unknown_embedder_is_refused_loudly
    error = assert_raises(ArgumentError) { VM.model_id("whisper") }
    assert_includes error.message, "wespeaker"
  end

  def test_the_importmap_pin_matches_the_runtime_version
    map = File.read(File.expand_path("../../../config/importmap.rb", __dir__))

    assert_includes map, "@huggingface/transformers@#{VM::TRANSFORMERS_VERSION}/"
  end
end
