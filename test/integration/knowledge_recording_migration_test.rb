# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "rake"
require_relative "../support/knowledge_recording_fixture"
require_relative "../../db/migrate/20261008120000_add_recording_to_studio_knowledge_docs"

# [integration] The recording migration against a consumer's EXISTING documents
# table, up and back down, with rows in it; then the whole path an operator
# runs: `rake studio:knowledge:attach_recording` on the migrated table, loaded
# from the engine's own .rake file, against a stubbed bucket.
#
# The table starts as a consumer has it today (the create migration plus the
# expectation column). All names are invented.
class KnowledgeRecordingMigrationTest < ActiveSupport::TestCase
  include KnowledgeRecordingFixture

  Doc = Studio::KnowledgeDoc
  MIGRATION = AddRecordingToStudioKnowledgeDocs
  COLUMNS = { "recording_key" => :string, "recording_mime_type" => :string,
              "recording_byte_size" => :integer, "recording_source_url" => :text }.freeze
  RAKE_FILE = File.expand_path("../../lib/tasks/studio_knowledge.rake", __dir__)
  ENV_KEYS = %w[ID FILE URL SOURCE_URL].freeze

  def connection = ActiveRecord::Base.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { MIGRATION.new.migrate(direction) }
    Doc.reset_column_information
  end

  setup do
    KnowledgeRecordingFixture.create_old_table!(connection)
    Doc.reset_column_information
    stub_storage!
    # No real DNS: every name these tests fetch resolves to one made-up public address.
    @previous_resolver = Studio::ImageCache.instance_variable_get(:@resolver)
    Studio::ImageCache.resolver = ->(_host) { ["93.184.216.34"] }
    @previous_env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    ENV_KEYS.each { |key| ENV.delete(key) }
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load RAKE_FILE
  end

  teardown do
    unstub_storage!
    Studio::ImageCache.resolver = @previous_resolver
    @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rake.application = Rake::Application.new
    connection.drop_table(:studio_knowledge_docs, if_exists: true)
    Doc.reset_column_information
  end

  def invoke_task(env)
    env.each { |key, value| ENV[key.to_s] = value.to_s }
    Rake::Task["studio:knowledge:attach_recording"].reenable
    Rake::Task["studio:knowledge:attach_recording"].invoke
  end

  def rake(**env)
    capture_io { invoke_task(env) }
  end

  def rake_aborts(**env)
    capture_io { assert_raises(SystemExit) { invoke_task(env) } }
  end

  # --- the migration ----------------------------------------------------------

  test "up adds the four columns and the unique index, and leaves existing rows alone" do
    doc = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls", s3_key: "knowledge/example-co/calls/a.txt")
    before = connection.select_all("SELECT * FROM studio_knowledge_docs").to_a
    refute doc.recording?

    migrate(:up)

    columns = connection.columns(:studio_knowledge_docs).to_h { |column| [column.name, column] }
    COLUMNS.each do |name, type|
      assert_equal type, columns.fetch(name).type, name
      assert columns.fetch(name).null, "#{name} is nullable: existing rows have none"
      assert_nil columns.fetch(name).default
    end
    assert_equal "bigint", columns.fetch("recording_byte_size").sql_type.downcase, "a recording passes 2 GB"
    index = connection.indexes(:studio_knowledge_docs).find { |i| i.columns == ["recording_key"] }
    assert index&.unique, "two rows may not claim one recording object"

    after = connection.select_all("SELECT * FROM studio_knowledge_docs").to_a
    assert_equal before, after.map { |row| row.except(*COLUMNS.keys) }
    assert Doc.recording_columns?
    refute Doc.find(doc.id).recording?
    Doc.create!(title: "Second call", entity: "example-co")
    assert_equal 2, Doc.where(recording_key: nil).count, "the unique index admits many rows with no recording"
  end

  test "down removes exactly what up added and the model reads as before" do
    doc = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls")
    shape = lambda do
      [connection.columns(:studio_knowledge_docs).map { |c| [c.name, c.sql_type, c.null, c.default] },
       connection.indexes(:studio_knowledge_docs).map { |i| [i.name, i.columns, i.unique] }.sort]
    end
    before = shape.call

    migrate(:up)
    Doc.find(doc.id).attach_recording!(recording_file)
    assert Doc.find(doc.id).recording?
    migrate(:down)

    assert_equal before, shape.call
    reloaded = Doc.find(doc.id)
    assert_equal "Weekly standup", reloaded.title
    assert_equal false, reloaded.recording?, "back on the old schema, a reader answers none"
    refute Doc.recording_columns?
  end

  test "the migration is the engine's newest for this table and its version is unique" do
    files = Dir[File.expand_path("../../db/migrate/*.rb", __dir__)].map { |path| File.basename(path) }
    versions = files.map { |name| name[/\A\d+/] }
    assert_equal versions.uniq, versions
    knowledge = files.grep(/knowledge/).sort
    assert_equal "20261008120000_add_recording_to_studio_knowledge_docs.rb", knowledge.last
    assert_includes Studio::Engine.paths["db/migrate"].existent.flat_map { |dir| Dir["#{dir}/*.rb"] }.map { |p| File.basename(p) },
                    knowledge.last, "studio_engine:install:migrations copies from this path"
  end

  # --- the rake task, on the migrated table ----------------------------------

  test "the task attaches a recording from a path and prints what it stored" do
    migrate(:up)
    doc = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls")
    out, = rake(ID: doc.id, FILE: recording_file, SOURCE_URL: "https://notes.example.com/calls/abc")

    doc.reload
    assert doc.recording?
    assert_equal %i[create_multipart_upload upload_part complete_multipart_upload head_object], operations
    assert_includes out, "Attached a recording to knowledge document #{doc.id} (Weekly standup)"
    assert_includes out, "bucket: example-app-dev"
    assert_includes out, "key:    #{doc.recording_key}"
    assert_includes out, "type:   video/mp4"
    assert_includes out, "size:   #{KnowledgeRecordingFixture::MP4.bytesize} bytes"
    assert_includes out, "link:   https://notes.example.com/calls/abc"
    refute_includes out, "replaced"
  end

  test "the task says what it replaced" do
    migrate(:up)
    doc = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls")
    rake(ID: doc.id, FILE: recording_file)
    first = doc.reload.recording_key
    out, = rake(ID: doc.id, FILE: recording_file)
    assert_includes out, "replaced #{first} (moved to trash/ for three days)"
    refute_equal first, doc.reload.recording_key
  end

  test "the task refuses a file that is not a recording and writes nothing" do
    migrate(:up)
    doc = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls")
    _out, err = rake_aborts(ID: doc.id, FILE: recording_file("customer list, not a recording", name: ["list", ".csv"]))
    assert_match(/NotARecording/, err)
    assert_empty operations
    refute doc.reload.recording?
  end

  test "the task fetches a URL through the guard and never prints the download address" do
    migrate(:up)
    doc = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls")
    path = recording_file
    original = Studio::KnowledgeRecording.method(:fetch)
    Studio::KnowledgeRecording.define_singleton_method(:fetch) { |_url, **_options, &block| block.call(path, "download") }
    begin
      out, err = rake(ID: doc.id, URL: "https://files.example.com/download?token=SECRET")
    ensure
      Studio::KnowledgeRecording.define_singleton_method(:fetch, original)
    end
    assert doc.reload.recording?
    refute_match(/SECRET|files\.example\.com/, out + err)

    _out, err = rake_aborts(ID: doc.id, URL: "https://127.0.0.1/download?token=SECRET")
    assert_match(/Refused/, err)
    refute_match(/SECRET/, err)
    _out, err = rake_aborts(ID: doc.id, URL: "http://files.example.com/download?token=SECRET")
    assert_match(/https only/, err)
    refute_match(/SECRET/, err)
  end

  test "the task wants an id and exactly one source" do
    migrate(:up)
    doc = Doc.create!(title: "Weekly standup", entity: "example-co")
    path = recording_file
    [{ FILE: path }, { ID: "abc", FILE: path }, { ID: "1; DROP", FILE: path }, { ID: doc.id },
     { ID: doc.id, FILE: path, URL: "https://files.example.com/a.mp4" }].each do |env|
      ENV_KEYS.each { |key| ENV.delete(key) }
      _out, err = rake_aborts(**env)
      assert_match(/usage: studio:knowledge:attach_recording/, err, env.inspect)
    end
    ENV_KEYS.each { |key| ENV.delete(key) }
    _out, err = rake_aborts(ID: doc.id + 999, FILE: path)
    assert_match(/no knowledge document with id #{doc.id + 999}/, err)
    assert_empty operations
  end

  test "on a table without the columns the task names the migration" do
    doc = Doc.create!(title: "Weekly standup", entity: "example-co")
    _out, err = rake_aborts(ID: doc.id, FILE: recording_file)
    assert_match(/MissingRecordingColumns/, err)
    assert_match(/studio_engine:install:migrations/, err)
    assert_empty operations
  end

  test "loading the rake file twice registers one task" do
    load RAKE_FILE
    assert_equal 1, Rake::Task["studio:knowledge:attach_recording"].actions.size
  end
end
