# frozen_string_literal: true

# The engine's Node tooling package (lib/studio/node_tooling/README.md). Neither
# task loads :environment; both need only Rails.root (Studio::NodeTooling.host_root).
namespace :studio do
  namespace :node do
    desc "Link studio-engine's Node tooling package at node_modules/.studio-engine (run after npm ci)"
    task :link do
      root = Studio::NodeTooling.host_root
      path = Studio::NodeTooling.link!(root)
      puts "studio-engine: #{path.relative_path_from(root)} -> #{Studio::NodeTooling.root}"
    end

    desc "Fail when this app's Node pins drift from studio-engine's versions.json"
    task :check do
      problems = Studio::NodeTooling.drift(Studio::NodeTooling.host_root)
      if problems.empty?
        puts "studio-engine: Node tooling matches the pins #{Studio::NodeTooling.versions.to_json}"
      else
        abort(["studio-engine: Node tooling drifts from the pins:", *problems.map { |p| "  - #{p}" }].join("\n"))
      end
    end
  end
end
