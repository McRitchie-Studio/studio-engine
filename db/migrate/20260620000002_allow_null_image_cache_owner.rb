# Lets ImageCache cache app-GLOBAL images (no owning record) — e.g. Studio::
# EmailImage stores the admin-managed email banners owner-less. Reference
# migration; each consumer app installs its own copy (the table is app-owned).
class AllowNullImageCacheOwner < ActiveRecord::Migration[7.2]
  def change
    # No-op on an app that doesn't use ImageCache. `image_caches` is app-owned,
    # so an app can install the engine's migrations without having that table —
    # and unguarded, this raised and failed the whole `db:migrate`.
    #
    # Deleting the copy is NOT a workaround: install:migrations builds its
    # skip-list from the files PRESENT, so a deleted copy is re-copied with a
    # fresh timestamp on the next upgrade and fails again. The guard has to live
    # here, in the migration, or it doesn't hold.
    return unless table_exists?(:image_caches)

    change_column_null :image_caches, :owner_type, true
    change_column_null :image_caches, :owner_id, true
  end
end
