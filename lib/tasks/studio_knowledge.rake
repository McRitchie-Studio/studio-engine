# frozen_string_literal: true

# Attach a meeting's recording to a knowledge document, from a one-off dyno or
# a laptop. The recording is COPIED into the app's private bucket beside the
# document.
#
#   bin/rails studio:knowledge:attach_recording ID=42 FILE=/tmp/standup.mp4
#   bin/rails studio:knowledge:attach_recording ID=42 URL=https://files.example.com/standup.mp4
#   bin/rails studio:knowledge:attach_recording ID=42 FILE=/tmp/standup.mp4 SOURCE_URL=https://notes.example.com/calls/abc
#
# ID is the document's id. Give exactly one of FILE (a local path) or URL (an
# https download, fetched through the engine's SSRF guard). SOURCE_URL is the
# external page the recording came from, kept on the row as a link; the URL
# download address itself is never stored or printed, because it usually
# carries a credential.
#
# The arguments are environment variables, not rake's [a,b] form, because a
# URL may hold a comma and rake splits on them.
#
# Only audio and video are stored: MP4, M4V, MOV, M4A, WebM, MP3, WAV and Ogg,
# judged by the file's first bytes (Studio::KnowledgeRecording), up to 4 GB.
# Anything else is refused and nothing is written. Replacing a recording moves
# the old object to trash/ for three days (studio:trash:restore).
#
# Logic lives in Studio::KnowledgeDoc#attach_recording! and
# #attach_recording_from_url! (unit-tested); this task only reads its
# arguments and prints.
# Guarded like studio_trash.rake: an app that also loads this file must not
# register a second copy of the action.
unless Rake::Task.task_defined?("studio:knowledge:attach_recording")
  namespace :studio do
    namespace :knowledge do
      desc "Attach a recording to knowledge document ID from FILE=<path> or URL=<https url> (SOURCE_URL=<page> optional)"
      task attach_recording: :environment do
        # Loaded up front: the rescue below names its error classes.
        require "studio/knowledge_recording"
        usage = "usage: studio:knowledge:attach_recording ID=<document id> (FILE=<path> | URL=<https url>) [SOURCE_URL=<page>]"
        id = ENV["ID"].to_s.strip
        file = ENV["FILE"].to_s.strip
        url = ENV["URL"].to_s.strip
        source_url = ENV["SOURCE_URL"].to_s.strip
        abort usage unless id.match?(/\A\d{1,18}\z/)
        abort "#{usage}\ngive FILE or URL, not both" unless file.empty? ^ url.empty?

        doc = Studio::KnowledgeDoc.find_by(id: id.to_i)
        abort "studio:knowledge:attach_recording: no knowledge document with id #{id}" if doc.nil?

        replaced = doc.recording? ? doc.recording_key : nil
        options = source_url.empty? ? {} : { source_url: source_url }
        begin
          if file.empty?
            doc.attach_recording_from_url!(url, **options)
          else
            doc.attach_recording!(file, **options)
          end
        rescue Studio::KnowledgeRecording::Error, Studio::KnowledgeDoc::Recording::MissingRecordingColumns,
               Studio::S3::Error, ActiveRecord::RecordInvalid, ArgumentError => error
          abort "studio:knowledge:attach_recording: #{error.class}: #{error.message}"
        end

        puts "Attached a recording to knowledge document #{doc.id} (#{doc.title})"
        puts "  bucket: #{Studio::S3.bucket}"
        puts "  key:    #{doc.recording_key}"
        puts "  type:   #{doc.recording_mime_type}"
        puts "  size:   #{doc.recording_byte_size} bytes"
        puts "  link:   #{doc.recording_link}" if doc.recording_link
        puts "  replaced #{replaced} (moved to trash/ for three days)" if replaced
      end
    end
  end
end
