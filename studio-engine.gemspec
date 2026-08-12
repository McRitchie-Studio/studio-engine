require_relative "lib/studio/version"

Gem::Specification.new do |spec|
  spec.name        = "studio-engine"
  spec.version     = Studio::VERSION
  spec.authors     = ["Alex McRitchie"]
  spec.email       = ["studio-engine@mcritchie.studio"]
  spec.summary     = "Shared Rails engine providing auth, SSO, error logging, theming, and S3-backed image caching"
  spec.description = "Studio Engine is a non-isolated Rails engine that ships an opinionated authentication + SSO contract, a polymorphic ErrorLog model, a Sluggable concern, a 7-role dynamic theme system with CSS-custom-property generation, and an S3-backed ImageCache. Used in production across the McRitchie Studio + Turf Monster apps."
  spec.homepage    = "https://github.com/McRitchie-Studio/studio-engine"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri"    => "https://github.com/McRitchie-Studio/studio-engine",
    "source_code_uri" => "https://github.com/McRitchie-Studio/studio-engine/tree/main",
    "bug_tracker_uri" => "https://github.com/McRitchie-Studio/studio-engine/issues",
    "changelog_uri"   => "https://github.com/McRitchie-Studio/studio-engine/blob/main/CHANGELOG.md"
  }

  # config/e2e_lane.yml is the BROWSER LANE's contract — a fact about this repo's CI,
  # read by bin/e2e-executed-set-check and test/lib/e2e_lane_contract_test.rb. It is
  # the only thing under config/, and it has no meaning in a consuming app, so it is
  # excluded rather than shipped. (e2e/, bin/ and test/ were never in this list.)
  spec.files = Dir["lib/**/*", "app/**/*", "config/**/*", "db/**/*", "tailwind/**/*", "Gemfile", "studio-engine.gemspec", "README.md", "CHANGELOG.md", "LICENSE"] - ["config/e2e_lane.yml"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 7.2", "< 8.2"
  spec.add_dependency "tailwindcss-rails", "~> 4.5"
  spec.add_dependency "faker", ">= 2.0", "< 4.0"
  spec.add_dependency "solid_queue", ">= 1.0", "< 2.0"
  spec.add_dependency "aws-sdk-s3", "~> 1.218"
  spec.add_dependency "mini_magick", "~> 5.0"
  spec.add_dependency "resend", "~> 1.1"
  # Realtime: the redis cable/cache/Sidekiq adapter (Studio::Redis) + Turbo Streams
  # broadcasting (Studio::Broadcastable). `redis` is the dependency whose ABSENCE
  # 500'd a host app's task board — declaring it here makes that impossible to repeat.
  spec.add_dependency "redis", ">= 4.0.1"
  spec.add_dependency "turbo-rails", ">= 1.0"
end
