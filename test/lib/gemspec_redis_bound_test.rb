# frozen_string_literal: true

# Guard: the engine's `redis` dependency stays below 6.
#
# WHY. ActionCable's redis pubsub adapter activates `gem "redis", ">= 4", "< 6"`
# on every Rails line this gemspec allows up to 8.1.3. With no ceiling here, a
# consumer that did not pin redis floated to 6.0.0 and its cable adapter failed
# to load (Cyvasse shipped live chat broken that way). This reads the gemspec
# itself, so it fails if the ceiling is dropped or widened past 5.x.

require "minitest/autorun"
require "rubygems"

class GemspecRedisBoundTest < Minitest::Test
  GEMSPEC = File.expand_path("../../studio-engine.gemspec", __dir__)

  def redis_requirement
    spec = Gem::Specification.load(GEMSPEC)
    refute_nil spec, "could not load #{GEMSPEC}"
    dep = spec.runtime_dependencies.find { |d| d.name == "redis" }
    refute_nil dep, "studio-engine.gemspec must declare a runtime redis dependency"
    dep.requirement
  end

  def test_excludes_redis_6
    refute redis_requirement.satisfied_by?(Gem::Version.new("6.0.0")),
           "redis 6.0.0 must not satisfy #{redis_requirement} (ActionCable needs < 6)"
  end

  def test_satisfies_redis_5_4_1
    assert redis_requirement.satisfied_by?(Gem::Version.new("5.4.1")),
           "redis 5.4.1 must satisfy #{redis_requirement}"
  end

  def test_keeps_the_floor
    refute redis_requirement.satisfied_by?(Gem::Version.new("4.0.0")),
           "the 4.0.1 floor must hold: #{redis_requirement}"
  end
end
