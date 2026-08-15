# `users.last_name` — the standard set's sixth column, and the reason it arrives
# in a migration of its own rather than in AddStandardUserProfileColumns.
#
# THAT MIGRATION IS ALREADY INSTALLED IN CONSUMERS, and an install-copy is a
# FILE in the app's own db/migrate with the app's own timestamp. Editing the gem
# side after that does not update the copies: `studio_engine:install:migrations`
# SKIPS a migration whose name is already installed, so the copy silently
# diverges from the gem, and if it has already run the app is left stamped on a
# body that no longer exists anywhere. turf-monster and mcritchie-industries both
# guard against exactly that (test/lib/engine_migration_content_test.rb, "every
# installed engine migration still matches the gem's copy") and both caught this
# on consumer CI the moment it was tried.
#
# So a shipped migration is immutable, and the standard SET is expressed across
# however many migrations it took to get there. Adding a column means adding a
# file.
#
# Same two safety properties as its predecessor, for the same reasons:
#
#   1. `if_not_exists` — mcritchie-studio and turf-monster have owned this column
#      since long before the engine had an opinion about it. An unguarded add
#      raises there, which is the failure mode that makes engine migrations
#      against a host's table frightening in the first place.
#   2. It no-ops on an app with no `users` table rather than raising. The
#      engine's own dummy is such an app.
#
# ON THE DOWN: it REFUSES, and for the same reason the standard-columns migration
# does. `if_not_exists` means this records nothing about whether it created the
# column or found it — and the two apps it was careful not to touch are exactly
# the two a DROP COLUMN would rob. `if_exists` is not the fix: it asks "does this
# column exist?", and on those apps it does. Refusing turns silent data loss into
# a loud, actionable error.
class AddLastNameToUsers < ActiveRecord::Migration[7.2]
  def up
    return unless table_exists?(:users)

    add_column :users, :last_name, :string, if_not_exists: true
  end

  def down
    return unless table_exists?(:users)

    raise ActiveRecord::IrreversibleMigration, <<~MSG
      AddLastNameToUsers cannot be reversed safely.

      Its `up` adds last_name with `if_not_exists`, so it does not know whether it
      created the column on this host or found it already there. mcritchie-studio
      and turf-monster both owned users.last_name before this migration existed;
      dropping it would destroy host-owned data.

      If you truly want the column gone on an app that did not own it before,
      drop it by hand, in its own migration.
    MSG
  end
end
