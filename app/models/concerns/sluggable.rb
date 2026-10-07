# A human-readable `slug` that is written once and changed only on purpose.
#
# The slug is set at create from `name_slug` (each including model defines it)
# and never recomputed by a later save, because other tables point at it by
# value: a display-name edit must not rename the row and orphan its children.
# A persisted row whose slug is blank gets one on its next save, since filling a
# blank is still the first write.
#
# The one way to change a persisted slug is `rename_slug!` (or `rename_slug`),
# which updates the row and every child column that references it in one
# transaction. The children are found two ways:
#
#   * every `has_many` / `has_one` on the model with `primary_key: :slug`;
#   * every pair declared with `has_slug_children`, for a table that has no
#     association here:
#
#       class Person < ApplicationRecord
#         include Sluggable
#         has_slug_children "athletes" => :person_slug,
#                           "news" => %i[primary_person_slug secondary_person_slug]
#       end
#
# The declaration lives on the parent so the cascade never depends on whether a
# child class happens to be loaded.
#
# A refusal (blank, badly formed, or taken) raises Sluggable::SlugRefused, a
# subclass of ActiveRecord::RecordInvalid, with the reason on `errors[:slug]`.
# Studio::ErrorHandling answers it with 422 and the reason, never a 500, and
# `rename_slug` returns false instead of raising, for an inline form error.
module Sluggable
  extend ActiveSupport::Concern

  # Lowercase words of letters and digits joined by single hyphens: the shape
  # `String#parameterize` produces. A model whose slugs legitimately hold other
  # characters sets its own `self.slug_format`.
  DEFAULT_SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  # The refusal rename_slug! raises: a RecordInvalid, so a caller that already
  # rescues RecordInvalid keeps working, with a class of its own so the
  # controller layer can answer it with 422 without claiming every invalid save.
  class SlugRefused < ActiveRecord::RecordInvalid; end

  included do
    class_attribute :slug_format, instance_writer: false, default: DEFAULT_SLUG_FORMAT
    class_attribute :declared_slug_children, instance_writer: false, default: [].freeze

    before_save :set_slug, if: :sluggable_unwritten?
  end

  class_methods do
    # Declares child columns that hold this model's slug: a hash of table name to
    # one column or a list of columns. Repeatable; each call adds to the set.
    def has_slug_children(pairs)
      added = pairs.flat_map do |table, columns|
        Array(columns).map { |column| [table.to_s, column.to_s].freeze }
      end
      self.declared_slug_children = (declared_slug_children + added).uniq.freeze
    end

    # Every [table, column] pair `rename_slug!` updates: the slug-keyed
    # associations plus the declared pairs, without duplicates.
    def slug_children
      from_associations = reflect_on_all_associations.filter_map do |reflection|
        next unless %i[has_many has_one].include?(reflection.macro)
        next if reflection.through_reflection? || reflection.polymorphic? || reflection.options[:as]
        next unless reflection.options[:primary_key].to_s == "slug"

        [reflection.klass.table_name, reflection.foreign_key.to_s].freeze
      end
      (from_associations + declared_slug_children).uniq
    end
  end

  def to_param
    slug
  end

  # Changes this row's slug to `new_slug` and rewrites every child column that
  # held the old one, all or nothing. Returns { "table.column" => rows updated }.
  # Raises Sluggable::SlugRefused, with the reason on errors[:slug], when
  # the slug is blank, badly formed, or already taken.
  def rename_slug!(new_slug)
    raise ActiveRecord::RecordNotSaved.new("a slug can be renamed only on a saved record", self) unless persisted?

    new_slug = new_slug.to_s.strip
    old_slug = slug_in_database
    errors.delete(:slug)
    return {} if new_slug == old_slug

    sluggable_refuse!(:blank) if new_slug.empty?
    sluggable_refuse!(:invalid) unless slug_format.match?(new_slug)
    sluggable_refuse!(:taken, value: new_slug) if sluggable_taken?(new_slug)

    renamed = { slug: new_slug }
    renamed[:updated_at] = Time.current if has_attribute?(:updated_at)
    counts = {}
    self.class.transaction(requires_new: true) do
      self.class.base_class.unscoped.where(self.class.primary_key => id).update_all(renamed)
      self.class.slug_children.each do |table, column|
        counts["#{table}.#{column}"] = sluggable_cascade(table, column, old_slug, new_slug)
      end
    end
    renamed.each { |name, value| write_attribute(name, value) }
    clear_attribute_changes(renamed.keys)
    counts
  rescue ActiveRecord::RecordNotUnique
    # The pre-check passed and a concurrent write took the slug first; the
    # unique index is the arbiter, and the answer is the same refusal.
    sluggable_refuse!(:taken, value: new_slug)
  rescue ActiveRecord::InvalidForeignKey
    sluggable_refuse!(:invalid, message: "cannot change while a constraint without ON UPDATE CASCADE references it")
  end

  # rename_slug! for a form: false, with the reason on errors[:slug], instead of
  # raising.
  def rename_slug(new_slug)
    rename_slug!(new_slug)
    true
  rescue SlugRefused
    false
  end

  private

  def sluggable_unwritten?
    new_record? || slug.blank?
  end

  def set_slug
    self.slug = name_slug
  end

  def sluggable_taken?(candidate)
    self.class.base_class.unscoped.where(slug: candidate).where.not(self.class.primary_key => id).exists?
  end

  # One UPDATE on the parent's connection: the cascade a foreign key with
  # ON UPDATE CASCADE would run, and it needs no model for the child table.
  def sluggable_cascade(table, column, old_slug, new_slug)
    connection = self.class.connection
    quoted_column = connection.quote_column_name(column)
    connection.update(<<~SQL.squish, "Sluggable cascade")
      UPDATE #{connection.quote_table_name(table)}
      SET #{quoted_column} = #{connection.quote(new_slug)}
      WHERE #{quoted_column} = #{connection.quote(old_slug)}
    SQL
  end

  def sluggable_refuse!(reason, **options)
    errors.add(:slug, reason, **options)
    raise SlugRefused, self
  end
end
