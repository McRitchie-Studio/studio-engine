# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

module Studio
  # The engine's Node tooling package (lib/studio/node_tooling/README.md): the
  # one pin set, the shared Playwright base and helpers, and the node:test hooks.
  #
  # The gem's path is resolved here in Ruby, never by Node running bundler (the
  # same rule Studio::TailwindEntry keeps). `link!` puts a symlink at a fixed
  # path in the host, so a host's playwright.config.js or test register file
  # requires `./node_modules/.studio-engine/...` with no shell-out.
  #
  # `drift` holds a host to the pins: Node's major in `.tool-versions` (what
  # mise and actions/setup-node's `node-version-file` read) and package.json
  # `engines`, and the exact version of every pinned package the host declares,
  # in package.json and in package-lock.json. A pinned package the host does not
  # declare is not drift: no host is made to install what it does not use.
  module NodeTooling
    ROOT = Pathname(__dir__).join("node_tooling").freeze
    LINK = "node_modules/.studio-engine"

    module_function

    def root = ROOT

    # The host the rake tasks act on. A method of its own so a test can point
    # the tasks at a temporary host without defining a Rails constant.
    def host_root = ::Rails.root

    def versions = JSON.parse(ROOT.join("versions.json").read)

    def link_path(app_root) = Pathname(app_root).join(LINK)

    # Idempotent. Replaces a stale link (an older gem's directory); refuses a
    # real directory or file at the path rather than deleting someone's work.
    def link!(app_root)
      path = link_path(app_root)
      if path.symlink?
        return path if path.readlink == ROOT

        path.delete
      elsif path.exist?
        raise ArgumentError, "#{path} exists and is not a symlink; move it aside and link again"
      end
      FileUtils.mkdir_p(path.dirname)
      File.symlink(ROOT, path)
      path
    end

    # Every way the host at `app_root` differs from versions.json, one sentence
    # each. Empty when it matches.
    def drift(app_root)
      app_root = Pathname(app_root)
      pins = versions
      major = pins.fetch("node")
      problems = node_version_drift(app_root, major)

      package = read_json(app_root.join("package.json"))
      return problems unless package

      engines = package.dig("engines", "node")
      unless engines == "#{major}.x"
        problems << "package.json engines.node is #{engines.inspect}; the pin is \"#{major}.x\""
      end

      lock = read_json(app_root.join("package-lock.json"))
      pins.except("node").each do |name, version|
        declared = package.dig("devDependencies", name) || package.dig("dependencies", name)
        next unless declared

        problems << "package.json declares #{name} #{declared.inspect}; the pin is \"#{version}\"" unless declared == version
        locked = lock&.dig("packages", "node_modules/#{name}", "version")
        problems << "package-lock.json locks #{name} at #{locked.inspect}; the pin is \"#{version}\"" unless locked == version
      end
      problems
    end

    def node_version_drift(app_root, major)
      file = app_root.join(".tool-versions")
      return ["no .tool-versions; it should read \"nodejs #{major}\""] unless file.file?

      line = file.read.lines.map(&:split).find { |tool, *| %w[nodejs node].include?(tool) }
      return [".tool-versions names no nodejs; it should read \"nodejs #{major}\""] unless line
      return [] if line[1] == major

      [".tool-versions reads \"#{line.join(" ")}\"; it should read \"nodejs #{major}\""]
    end

    def read_json(path)
      path.file? ? JSON.parse(path.read) : nil
    end
  end
end
