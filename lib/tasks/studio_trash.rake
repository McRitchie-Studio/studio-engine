# frozen_string_literal: true

# Find and restore objects Studio::S3.delete or the StudioTrashS3 Active Storage
# service moved under trash/. The bucket's lifecycle rule expires trash/ after
# three days; after that there is nothing to restore.
#
#   bin/rails "studio:trash:list"                       # everything in trash
#   bin/rails "studio:trash:list[avatars/abc.png]"      # one key's trash copies
#   bin/rails "studio:trash:restore[trash/2026-10-01/1759302000123/avatars/abc.png]"
#
# The bucket is Studio::S3's. SERVICE=<storage.yml service name> reads an Active
# Storage service's bucket instead (e.g. SERVICE=r2_production). FORCE=1 lets a
# restore overwrite an object that already sits at the original key.
#
# Logic lives in Studio::S3::Trash (unit-tested); these tasks only resolve the
# bucket and print.
# Guarded like studio_email.rake and studio_ses.rake: an app that also loads
# this file must not register a second copy of each action.
unless Rake::Task.task_defined?("studio:trash:restore")
  namespace :studio do
    namespace :trash do
      def studio_trash_target
        name = ENV["SERVICE"].to_s.strip
        if name.empty?
          { client: Studio::S3.client, bucket: Studio::S3.bucket, key_prefix: Studio::S3.key_prefix }
        else
          service = ActiveStorage::Blob.services.fetch(name.to_sym)
          { client: service.client.client, bucket: service.bucket.name, key_prefix: "" }
        end
      end

      desc "List trashed objects, optionally only those deleted from KEY"
      task :list, [:key] => :environment do |_task, args|
        target = studio_trash_target
        key = args[:key].to_s.strip
        # A Studio::S3 caller thinks in LOGICAL keys; the trash records the real
        # one. Match either, so the key you passed to delete finds its copy.
        wanted = key.empty? ? nil : [key, "#{target[:key_prefix]}#{key}"].uniq
        objects = Studio::S3::Trash.list(client: target[:client], bucket: target[:bucket])
        objects = objects.select { |object| wanted.include?(Studio::S3::Trash.original_key(object.key)) } if wanted

        puts "#{objects.size} trashed object(s) in #{target[:bucket]}#{" for #{key}" if wanted}"
        objects.each do |object|
          puts "#{object.key}  #{object.size} bytes  #{object.last_modified&.utc&.iso8601}"
        end
      end

      desc "Copy TRASH_KEY back to its original key (FORCE=1 overwrites)"
      task :restore, [:trash_key] => :environment do |_task, args|
        trash_key = args[:trash_key].to_s.strip
        abort "usage: studio:trash:restore[trash/<date>/<ms>/<key>]" if trash_key.empty?

        target = studio_trash_target
        overwrite = %w[1 true yes].include?(ENV["FORCE"].to_s.downcase)
        begin
          original = Studio::S3::Trash.restore!(client: target[:client], bucket: target[:bucket],
                                                trash_key: trash_key, overwrite: overwrite)
          attributes = Studio::S3::Trash.blob_attributes(client: target[:client], bucket: target[:bucket],
                                                         trash_key: trash_key)
        rescue Studio::S3::Error => error
          abort "studio:trash:restore: #{error.message}"
        end

        puts "Restored #{target[:bucket]}/#{original}"
        puts
        puts "If this was an Active Storage object, its blob row is gone. Recreate it and re-attach:"
        puts
        puts "  blob = ActiveStorage::Blob.create!("
        puts "    key: #{attributes[:key].inspect},"
        puts "    filename: #{(attributes[:filename] || 'FILENAME').inspect},"
        puts "    content_type: #{attributes[:content_type].inspect},"
        puts "    byte_size: #{attributes[:byte_size]},"
        puts "    checksum: #{attributes[:checksum].inspect},"
        puts "    service_name: #{(ENV['SERVICE'].to_s.strip.empty? ? 'SERVICE_NAME' : ENV['SERVICE'].strip).inspect}"
        puts "  )"
        puts "  record.photo.attach(blob)   # the record and attachment it belonged to"
        puts
        puts "A nil checksum means a multipart upload, whose ETag is not an MD5. Compute it"
        puts "from the restored bytes: Digest::MD5.base64digest(<downloaded bytes>)."
      end
    end
  end
end
