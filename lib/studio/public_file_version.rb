# frozen_string_literal: true

require "digest"

module Studio
  # A content version for a file in the host's public/ directory, so a link to
  # it changes when the file does (task footer-stacked-logo). Browsers cache a
  # favicon per origin and a hard reload does not reliably clear it: a redrawn
  # /favicon.png kept showing the old picture, both on a localhost port reused
  # by another desk and for returning production visitors. A versioned URL is
  # a new resource, so nobody has to bump anything by hand.
  #
  #   Studio::PublicFileVersion.path("/favicon.png")
  #     # => "/favicon.png?v=1a2b3c4d" (the first 8 hex of the file's SHA-256)
  #     # => "/favicon.png"            when the host has no such file
  #
  # The digest is read once per file contents: it is cached by the file's
  # path, size and mtime, so a process reads each file once and a file
  # redrawn in development gets its new version on the next request.
  module PublicFileVersion
    LENGTH = 8
    @versions = {}
    @lock = Mutex.new

    module_function

    # The path with `?v=<digest>` when root/path is a file, else the path as given.
    def path(path, root: default_root)
      version = version(path, root: root)
      version ? "#{path}?v=#{version}" : path
    end

    # The first LENGTH hex characters of the file's SHA-256, or nil when it is not a file.
    def version(path, root: default_root)
      return nil if root.nil?

      file = File.join(root.to_s, path.to_s.delete_prefix("/"))
      stat = File.stat(file)
      return nil unless stat.file?

      key = [file, stat.size, stat.mtime.to_r]
      @lock.synchronize { @versions[key] ||= Digest::SHA256.file(file).hexdigest[0, LENGTH] }
    rescue SystemCallError
      nil
    end

    def default_root
      ::Rails.public_path if defined?(::Rails.public_path) && ::Rails.respond_to?(:public_path)
    end

    def reset!
      @lock.synchronize { @versions.clear }
    end
  end
end
