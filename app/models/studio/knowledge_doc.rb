module Studio
  # One row per document in an entity's knowledge layer: the S3 object pointer,
  # the filing metadata (entity, folder path, category, as-of date), and the
  # per-agent access map that says who may read it and at what depth.
  #
  # The access model has three levels, because "not allowed to read it" and
  # "does not know it exists" are different states:
  #
  #   full  — the agent reads the document and its facts.
  #   aware — the agent knows the document exists and gets `summary` (the safe
  #           summary + boundary line), not the contents. An agent with a HOLE
  #           in its context confabulates or stonewalls; one with an awareness
  #           entry has something true to say and a boundary to hold.
  #   none  — the agent does not see the row at all (the default).
  #
  # Folders are implicit: a document claims a `path` and the folder exists.
  # The S3 key mirrors entity + path, so the bucket stays human-browsable.
  # Uploads land as status "inbox" for agent triage (the knowledge-intake SOP);
  # filing flips them "filed"; a replacement marks the old row "superseded".
  #
  # Storage goes through Studio::S3 and FAILS LOUDLY on an unconfigured app
  # (Studio::S3::NotConfigured) — never wrap intake in a rescue that returns
  # success; a QA lane once lost weeks of writes to exactly that.
  #
  # Like Studio::Link, the table is installed per consumer app by
  # `bin/rails studio_engine:install:migrations && bin/rails db:migrate`.
  class KnowledgeDoc < ApplicationRecord
    self.table_name = "studio_knowledge_docs"

    # The app drew knowledge routes but never installed the table. Raised in
    # place of a bare PG::UndefinedTable so the first person to hit it reads
    # the fix instead of an adapter error — see .intake!.
    class MissingTable < StandardError; end

    ACCESS_LEVELS = %w[full aware none].freeze
    STATUSES      = %w[inbox filed superseded].freeze

    validates :title,  presence: true
    validates :entity, presence: true
    validates :status, inclusion: { in: STATUSES }
    validate  :access_levels_are_known

    before_validation :normalize_fields

    scope :for_entity, ->(entity) { where(entity: entity) }
    scope :inbox,      -> { where(status: "inbox") }
    scope :filed,      -> { where(status: "filed") }
    scope :active,     -> { where.not(status: "superseded") }
    scope :in_folder,  ->(path) { where(path: normalize_path(path)) }
    scope :under, lambda { |base|
      base = normalize_path(base)
      base.empty? ? all : where("path = ? OR path LIKE ?", base, "#{base}/%")
    }

    class << self
      # Create + upload in one call — the write path the intake UI and the
      # knowledge-intake SOP use. `file` responds to #read (an uploaded file);
      # metadata-only records (file: nil) are legal.
      #
      # Table-missing is checked up front so the failure names its fix before
      # any bytes reach S3.
      def intake!(attrs, file: nil)
        unless table_exists?
          raise MissingTable,
                "The knowledge layer needs the studio_knowledge_docs table, and #{Studio.app_name} has " \
                "no such table. Run `bin/rails studio_engine:install:migrations && bin/rails db:migrate` " \
                "(install ALL of them). Do not hand-copy the migration — it collides with the installed " \
                "copy on `class CreateStudioKnowledgeDocs`."
        end

        doc = new(attrs)
        doc.title = default_title(file) if doc.title.blank? && file
        doc.validate!
        doc.attach!(file) if file
        doc.save!
        doc
      end

      # Immediate child folder names under `base` for this scope, derived from
      # the paths documents actually claim — there is no folder table.
      #
      # unscope(:order) is load-bearing: callers hand in display-ordered scopes,
      # and Postgres refuses SELECT DISTINCT with an ORDER BY column outside the
      # select list (SQLite tolerates it, so only a real consumer sees the 500).
      def folders_under(base = "")
        base   = normalize_path(base)
        prefix = base.empty? ? "" : "#{base}/"
        unscope(:order).distinct.pluck(:path).filter_map { |path|
          next if path == base || !path.start_with?(prefix)

          path.delete_prefix(prefix).split("/").first
        }.uniq.sort
      end

      # "/a//b/" -> "a/b". Nil-safe; the empty string is the root folder.
      # Dot segments are dropped ("a/../b" -> "a/b"): harmless server-side, but
      # the S3 key mirrors the path and a ".." reads as traversal to every
      # scanner and human who ever greps the bucket.
      def normalize_path(value)
        value.to_s.strip.squeeze("/").split("/")
             .reject { |segment| segment.empty? || segment == "." || segment == ".." }
             .join("/")
      end

      def default_title(file)
        name = file.respond_to?(:original_filename) ? file.original_filename : File.basename(file.to_s)
        File.basename(name.to_s, ".*").tr("_-", "  ").squeeze(" ").strip.presence
      end
    end

    # --- access ---------------------------------------------------------------

    # The queried agent is normalized the same way written keys are, so a
    # capitalized Studio.knowledge_agents roster entry reads its real level
    # instead of silently defaulting to "none".
    def access_for(agent)
      level = access.is_a?(Hash) ? access[agent.to_s.strip.downcase] : nil
      ACCESS_LEVELS.include?(level) ? level : "none"
    end

    # full or aware — the agent may know this document exists.
    def visible_to?(agent)
      access_for(agent) != "none"
    end

    def full_for?(agent)
      access_for(agent) == "full"
    end

    # --- storage --------------------------------------------------------------

    def file?
      s3_key.present?
    end

    # Upload the file's bytes and point this row at them. The key mirrors
    # entity + path so the bucket reads like the folder tree. Raises
    # Studio::S3::NotConfigured on an app with no bucket — deliberately.
    def attach!(file)
      filename = file.respond_to?(:original_filename) ? file.original_filename : File.basename(file.to_s)
      content_type = file.respond_to?(:content_type) ? file.content_type : nil
      body = file.respond_to?(:read) ? file.read : file.to_s

      # The random suffix is load-bearing: the timestamp is second-granularity,
      # so two same-named uploads in one second would otherwise write the same
      # key — the second S3 PUT overwrites the first object BEFORE the unique
      # index rejects the second row (found in PR #251 review, twice over).
      key = [
        "knowledge", entity, path.presence,
        "#{Time.current.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(4)}-#{self.class.sanitize_filename(filename)}"
      ].compact.join("/")

      Studio::S3.upload(key: key, body: body, content_type: content_type)
      self.s3_key    = key
      self.mime_type = content_type if content_type
      self.byte_size = body.bytesize if body.respond_to?(:bytesize)
      self
    end

    # 15-minute presigned GET — the only way a private object leaves the bucket.
    def signed_url(expires_in: 900)
      raise Studio::S3::Error, "no file attached to #{title.inspect}" unless file?

      Studio::S3.signed_url(key: s3_key, expires_in: expires_in)
    end

    # --- lifecycle ------------------------------------------------------------

    def supersede_with!(replacement)
      update!(status: "superseded", superseded_by_id: replacement.id)
    end

    def superseded?
      status == "superseded"
    end

    def folder_segments
      path.blank? ? [] : path.split("/")
    end

    # The date the row sorts and displays by: the document's own as-of date,
    # falling back to upload time for undated material.
    def display_date
      document_date || created_at&.to_date
    end

    def self.sanitize_filename(name)
      base = name.to_s.strip
      return "document" if base.empty?

      base.gsub(/[^A-Za-z0-9._-]+/, "-").squeeze("-")
          .gsub(/-(?=\.)|\A-|-\z/, "").downcase
          .presence || "document"
    end

    private

    def normalize_fields
      self.path   = self.class.normalize_path(path)
      self.entity = entity.to_s.strip.downcase if entity
      if access.is_a?(Hash)
        self.access = access.each_with_object({}) do |(agent, level), map|
          map[agent.to_s.strip.downcase] = level.to_s.strip.downcase if agent.present?
        end
      end
    end

    def access_levels_are_known
      return if access.blank?
      return errors.add(:access, "must be a map of agent => level") unless access.is_a?(Hash)

      access.each do |agent, level|
        unless ACCESS_LEVELS.include?(level)
          errors.add(:access, "level for #{agent.inspect} must be one of #{ACCESS_LEVELS.join(', ')}")
        end
      end
    end
  end
end
