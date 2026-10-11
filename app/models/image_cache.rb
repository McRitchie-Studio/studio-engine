class ImageCache < ApplicationRecord
  # Where a row's object lives (the `stored_in` column):
  #
  #   nil / "own"   this process's own bucket, at Studio.s3_public_url. Every row
  #                 written before the column existed, and every upload.
  #   "production"  a REFERENCE to production's copy, recorded by a
  #                 non-production seeder (Studio::ImageCache.reference_or_cache!)
  #                 instead of uploading a duplicate. It resolves on
  #                 Studio.s3_production_public_url.
  #
  # A plain string, not an AR enum: the column arrives by an engine migration a
  # host installs on its own schedule, and an enum declared on an absent column
  # raises at load. Without the column every row reads as "own", as before.
  STORED_IN = %w[own production].freeze
  OWN = "own"
  PRODUCTION = "production"

  # Optional so app-GLOBAL images (no owning record) can be cached too — e.g.
  # Studio::EmailCatalog stores the admin-managed email banners owner-less. Per-
  # record images (athlete/coach headshots) still set an owner; the
  # variant-uniqueness scope below keeps both shapes distinct.
  belongs_to :owner, polymorphic: true, optional: true

  validates :purpose, :variant, :s3_key, presence: true
  validates :s3_key, uniqueness: true
  validates :variant, uniqueness: { scope: [:owner_type, :owner_id, :purpose] }
  validates :stored_in, inclusion: { in: STORED_IN }, allow_nil: true, if: -> { has_attribute?(:stored_in) }

  def self.stored_in_column?
    table_exists? && column_names.include?("stored_in")
  end

  def production_reference?
    has_attribute?(:stored_in) && stored_in == PRODUCTION
  end

  # In production both kinds resolve on the app's own host, which IS
  # production's, so a production app's URLs are what they always were.
  def url
    production_reference? ? Studio::S3.production_url(key: s3_key) : Studio::S3.url(key: s3_key)
  end

  # The object's bytes, read from the bucket that holds them (read-only for a
  # production reference). Use this, not Studio::S3.download(key: s3_key),
  # which reads this process's own bucket.
  def download(max_bytes: nil)
    if production_reference?
      Studio::S3.production_download(key: s3_key, max_bytes: max_bytes)
    else
      Studio::S3.download(key: s3_key, max_bytes: max_bytes)
    end
  end

  # Removes the row's OBJECT (to trash, via Studio::S3.delete). A production
  # reference outside production is not this process's object: nothing is
  # deleted from either bucket (the own bucket may hold an unrelated object
  # under the same key) and nil is returned. Destroying the row itself is
  # always fine. In production a reference is an ordinary own object.
  def delete_object!
    return nil if production_reference? && !Studio::S3.production_environment?

    Studio::S3.delete(key: s3_key)
  end
end
