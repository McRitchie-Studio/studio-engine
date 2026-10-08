# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "rake"
require "stringio"
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
  ENV_KEYS = %w[ID FILE URL NAME SOURCE_URL].freeze

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

  test "the task attaches a recording from a path and prints the id, bucket, key, type and size" do
    migrate(:up)
    doc = Doc.create!(title: "Privileged Title Words", entity: "example-co", path: "calls")
    out, err = rake(ID: doc.id, FILE: recording_file, SOURCE_URL: "https://notes.example.com/calls/abc", NAME: "Standup.mp4")

    doc.reload
    assert doc.recording?
    assert_equal %i[create_multipart_upload upload_part complete_multipart_upload head_object], operations
    assert_equal "https://notes.example.com/calls/abc", doc.recording_link
    assert doc.recording_key.end_with?("-recording-standup.mp4")
    assert_equal <<~OUT, out
      Attached a recording to knowledge document #{doc.id}
        bucket: example-app-dev
        key:    #{doc.recording_key}
        type:   video/mp4
        size:   #{KnowledgeRecordingFixture::MP4.bytesize} bytes
    OUT
    # The output goes to a log: no title (content of the layer), no link.
    refute_match(/Privileged|Title|notes\.example\.com/, out + err)
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

  def with_stubbed_fetch(path)
    seen = []
    original = Studio::KnowledgeRecording.method(:fetch)
    Studio::KnowledgeRecording.define_singleton_method(:fetch) do |url, **_options, &block|
      seen << url
      block.call(path)
    end
    yield seen
  ensure
    Studio::KnowledgeRecording.define_singleton_method(:fetch, original)
  end

  def with_stdin(text)
    original = $stdin
    $stdin = StringIO.new(text)
    yield
  ensure
    $stdin = original
  end

  test "the task fetches a URL through the guard and never prints any of it" do
    migrate(:up)
    doc = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls")
    out = err = nil
    with_stubbed_fetch(recording_file) do
      out, err = rake(ID: doc.id, URL: "https://files.example.com/dl/PATH-SECRET?token=SECRET")
    end
    assert doc.reload.recording?
    refute_match(/SECRET|files\.example\.com|\/dl\//, out + err + doc.recording_key)

    _out, err = rake_aborts(ID: doc.id, URL: "https://127.0.0.1/dl/PATH-SECRET?token=SECRET")
    assert_match(/Refused/, err)
    refute_match(/SECRET/, err)
    _out, err = rake_aborts(ID: doc.id, URL: "http://files.example.com/dl/PATH-SECRET?token=SECRET")
    assert_match(/https only/, err)
    refute_match(/SECRET/, err)
  end

  # A command line is logged; standard input is not.
  test "URL=- reads the download URL from standard input" do
    migrate(:up)
    doc = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls")
    with_stubbed_fetch(recording_file) do |seen|
      with_stdin("  https://files.example.com/dl/PATH-SECRET?token=SECRET  \nsecond line is ignored\n") { rake(ID: doc.id, URL: "-") }
      assert_equal ["https://files.example.com/dl/PATH-SECRET?token=SECRET"], seen
    end
    assert doc.reload.recording?

    with_stdin("") do
      _out, err = rake_aborts(ID: doc.id, URL: "-")
      assert_match(/standard input held no URL/, err)
    end
    with_stdin("https://files.example.com/#{'a' * 20_000}\n") do
      _out, err = rake_aborts(ID: doc.id, URL: "-")
      assert_match(/Refused/, err, "no more of standard input is read than a URL may be long")
    end
  end

  # A storage or database error is reported like every other failure: its
  # class and message, one line, no `rake aborted!` backtrace.
  test "a storage failure aborts with one line naming the error" do
    migrate(:up)
    doc = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls")
    @client.stub_responses(:upload_part, "InternalError")
    _out, err = rake_aborts(ID: doc.id, FILE: recording_file)
    assert_match(/\Astudio:knowledge:attach_recording: Aws::S3::Errors::InternalError: /, err)
    assert_equal 1, err.lines.size
    refute doc.reload.recording?
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
