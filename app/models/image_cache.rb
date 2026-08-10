class ImageCache < ApplicationRecord
  # Optional so app-GLOBAL images (no owning record) can be cached too — e.g.
  # Studio::EmailCatalog stores the admin-managed email banners owner-less. Per-
  # record images (athlete/coach headshots) still set an owner; the
  # variant-uniqueness scope below keeps both shapes distinct.
  belongs_to :owner, polymorphic: true, optional: true

  validates :purpose, :variant, :s3_key, presence: true
  validates :s3_key, uniqueness: true
  validates :variant, uniqueness: { scope: [:owner_type, :owner_id, :purpose] }

  def url
    Studio::S3.url(key: s3_key)
  end
end
