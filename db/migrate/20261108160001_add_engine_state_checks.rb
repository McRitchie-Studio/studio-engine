# The engine's two state columns take the hub's state standard: a CHECK named
# `<table>_<column>_known` holding the list the model validates against, so a
# write that skips validations (update_columns, update_all, insert_all, raw SQL)
# is refused by the database (database audit 2026-11-07, finding 6).
#
#   studio_links.kind             Studio::LinkToken::KINDS (Studio::Link validates it)
#   studio_knowledge_docs.status  Studio::KnowledgeDoc::STATUSES
#
# The lists below are this migration's own frozen copy. A new value needs a new
# migration: test/integration/engine_state_checks_test.rb fails while a model's
# list and this copy differ.
#
# A host without the table is skipped, and a constraint already there is left
# alone, so a second run changes nothing. Both columns are NOT NULL already.
#
# A row outside its list stops the migration before any change, with the table,
# the column and the stray values in the message: the constraint is validated,
# so it cannot go on over such a row. Production on 2026-11-08 held none (every
# app with a database, read-only counts): studio_links holds magic_link and
# referral, studio_knowledge_docs holds filed and superseded (industries alone).
# The validating scan is short (the largest table is 366 rows). On Postgres the
# ALTER waits at most LOCK_TIMEOUT for its lock; a migrate that cannot get it
# fails whole and runs again on the next release.
class AddEngineStateChecks < ActiveRecord::Migration[7.2]
  LOCK_TIMEOUT = "10s"

  CHECKS = {
    "studio_links.kind" => %w[magic_link referral],
    "studio_knowledge_docs.status" => %w[inbox filed superseded]
  }.freeze

  # The constraint's name: `<table>_<column>_known`, as the hub names its own.
  def self.constraint_name(key) = key.tr(".", "_") + "_known"

  def up
    set_lock_timeout
    CHECKS.each do |key, values|
      table, column = key.split(".")
      next unless table_exists?(table)
      next if check_constraint_exists?(table, name: self.class.constraint_name(key))

      refuse_strays!(table, column, values)
      add_check_constraint table, "#{connection.quote_column_name(column)} IN (#{list(values)})",
                           name: self.class.constraint_name(key)
    end
  end

  def down
    CHECKS.each_key do |key|
      table, = key.split(".")
      next unless table_exists?(table)

      remove_check_constraint table, name: self.class.constraint_name(key), if_exists: true
    end
  end

  private

  def set_lock_timeout
    return unless connection.adapter_name.downcase.include?("postgres")

    execute "SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'"
  end

  def list(values) = values.map { |value| connection.quote(value) }.join(", ")

  def refuse_strays!(table, column, values)
    col = connection.quote_column_name(column)
    strays = connection.select_rows(<<~SQL.squish)
      SELECT #{col}, COUNT(*) FROM #{connection.quote_table_name(table)}
      WHERE #{col} IS NOT NULL AND #{col} NOT IN (#{list(values)}) GROUP BY #{col} ORDER BY #{col}
    SQL
    return if strays.empty?

    found = strays.map { |value, count| "#{value.inspect} (#{count})" }.join(", ")
    raise ActiveRecord::MigrationError,
          "#{table}.#{column} holds values outside #{values.inspect}: #{found}. " \
          "Resolve those rows, then migrate again."
  end
end
