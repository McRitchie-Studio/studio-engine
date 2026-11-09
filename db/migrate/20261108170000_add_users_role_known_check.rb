# CHECK users_role_known on the host's `users.role` (database audit 2026-11-07,
# section 3): the database half of Studio::Account's role validation, so a
# mistyped role is refused rather than saved as a quiet non-admin.
#
# THIS IS A MIGRATION AGAINST A HOST TABLE, shipped like the standard profile
# columns (20260813220000): install-copied with
# `bin/rails studio_engine:install:migrations`, never auto-run, and safe on an
# app that already disagrees.
#
#   * No `users` table, no `role` column, or a role that is not a string (an
#     integer enum): skipped.
#   * A CHECK named users_role_known already there: skipped. The hub and Turf
#     installed their own on 2026-11-08, narrowed to viewer + admin, and a host's
#     narrower CHECK is the stronger guard; this one is the ceiling.
#   * A row holding a role outside the list: REFUSED, naming the values, with
#     nothing written. A stray role is a product call (Turf's "user" meant
#     viewer); this migration does not guess it.
#
# Then it fills a NULL role with "viewer", sets NOT NULL, and adds the CHECK.
#
# The list is SPELLED OUT, not read from Studio::Roles: a migration is a record
# that must still run years from now, and a live constant may move. Widening the
# engine's list is a new migration that replaces this CHECK.
class AddUsersRoleKnownCheck < ActiveRecord::Migration[7.2]
  ROLES = %w[viewer member admin].freeze
  NAME = "users_role_known"

  def up
    return unless string_role?
    return if check_constraint_exists?(:users, name: NAME)

    allowed = ROLES.map { |role| connection.quote(role) }.join(", ")
    unknown = select_values("SELECT DISTINCT role FROM users WHERE role IS NOT NULL AND role NOT IN (#{allowed})")
    if unknown.any?
      raise ActiveRecord::MigrationError, <<~MSG
        AddUsersRoleKnownCheck refused: users.role holds #{unknown.sort.map(&:inspect).join(', ')},
        outside Studio::Roles (#{ROLES.join(', ')}). Move those rows to a known role in a
        migration of this app's own (Turf moved "user" to "viewer"), then run this again.
      MSG
    end

    execute "UPDATE users SET role = 'viewer' WHERE role IS NULL"
    change_column_null :users, :role, false
    add_check_constraint :users, "role IN (#{allowed})", name: NAME
  end

  # Removes the CHECK only when it is this migration's: one that names every
  # engine role. A host's own users_role_known, which `up` left in place, is
  # narrower (the hub's and Turf's name viewer and admin only) and stays. NOT
  # NULL stays too: `up` cannot record whether the host had it already, and a
  # NULL role is the one value no host wants back.
  def down
    return unless string_role?

    ours = check_constraints(:users).find { |check| check.name == NAME }
    return unless ours && ROLES.all? { |role| ours.expression.include?("'#{role}'") }

    remove_check_constraint :users, name: NAME
  end

  private

  def string_role?
    return false unless table_exists?(:users)

    column = columns(:users).find { |c| c.name == "role" }
    column && %i[string text].include?(column.type)
  end
end
