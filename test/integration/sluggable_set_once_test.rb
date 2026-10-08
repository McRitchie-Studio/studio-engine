# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [unit] Sluggable against real ActiveRecord rows: the slug is written once at
# create, a later save never recomputes it, and rename_slug! moves the row and
# every child column that holds its slug in one transaction.
#
# The children cover both ways a parent names them: `athletes` through a
# `has_many ... primary_key: :slug`, and `news` and `aliases` through
# `has_slug_children`, which needs no model. `aliases.person_slug` is uniquely
# indexed so a cascade can fail AFTER the parent and the earlier children were
# written, which is what proves the rollback.
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :people, force: true do |t|
    t.string :name
    t.string :slug
    t.timestamps
    t.index :slug, unique: true
  end

  create_table :athletes, force: true do |t|
    t.string :person_slug
  end

  create_table :news, force: true do |t|
    t.string :primary_person_slug
    t.string :secondary_person_slug
  end

  create_table :aliases, force: true do |t|
    t.string :person_slug
    t.index :person_slug, unique: true
  end
end

class SluggablePerson < ApplicationRecord
  self.table_name = "people"
  include Sluggable

  has_many :athletes, class_name: "SluggableAthlete", foreign_key: :person_slug, primary_key: :slug
  has_slug_children "news" => %i[primary_person_slug secondary_person_slug]
  has_slug_children "aliases" => :person_slug

  def name_slug
    name.to_s.parameterize
  end
end

# name_slug reads the id, which does not exist when before_save runs.
class SluggableAccount < ApplicationRecord
  self.table_name = "people"
  include Sluggable

  def name_slug
    "account-#{id}"
  end
end

# Owns its slug: an explicit value wins, and the post-insert settle stays out.
class SluggableExplicit < ApplicationRecord
  self.table_name = "people"
  include Sluggable

  def name_slug
    "derived-#{id}"
  end

  private

  def set_slug
    self.slug = "explicit-#{name.to_s.parameterize}" if slug.blank?
  end
end

class SluggableAthlete < ApplicationRecord
  self.table_name = "athletes"
end

class SluggableSetOnceTest < ActiveSupport::TestCase
  def setup
    %w[people athletes news aliases].each { |table| ActiveRecord::Base.connection.execute("DELETE FROM #{table}") }
    @person = SluggablePerson.create!(name: "Pat Passer")
  end

  def column(table, name)
    ActiveRecord::Base.connection.select_values("SELECT #{name} FROM #{table} ORDER BY id")
  end

  # --- written once -----------------------------------------------------------

  test "create writes the slug from name_slug" do
    assert_equal "pat-passer", @person.slug
    assert_equal "pat-passer", @person.to_param
  end

  test "a name change keeps the slug" do
    @person.update!(name: "Pat Renamed")

    assert_equal "pat-passer", @person.reload.slug
  end

  test "a persisted row with a blank slug gets one on its next save" do
    @person.update_column(:slug, nil)

    @person.update!(name: "Pat Filled")

    assert_equal "pat-filled", @person.reload.slug
  end

  test "a name_slug that reads the id is settled inside the create" do
    first = SluggableAccount.create!(name: "One")
    second = SluggableAccount.create!(name: "Two")

    assert_equal "account-#{first.id}", first.slug
    assert_equal "account-#{second.id}", second.reload.slug
  end

  test "a model that overrides set_slug keeps the slug it wrote" do
    row = SluggableExplicit.create!(name: "Kept")

    assert_equal "explicit-kept", row.reload.slug
  end

  # --- changed only through rename_slug! ---------------------------------------

  test "update slug on persisted record is invalid" do
    SluggableAthlete.create!(person_slug: "pat-passer")

    refute @person.update(slug: "pat-direct")
    assert_equal ["changes only through rename_slug!"], @person.errors[:slug]
    assert @person.errors.of_kind?(:slug, :readonly)
    assert_raises(ActiveRecord::RecordInvalid) { @person.update!(slug: "") }
    assert_equal "pat-passer", SluggablePerson.find(@person.id).slug
    assert_equal %w[pat-passer], column("athletes", "person_slug")
  end

  test "rename slug cascades with the guard on" do
    SluggableAthlete.create!(person_slug: "pat-passer")

    @person.rename_slug!("pat-the-passer")

    assert_equal %w[pat-the-passer], column("athletes", "person_slug")
    assert @person.update(name: "Pat Renamed"), "a save after a rename is not a slug change"
    assert_equal "pat-the-passer", @person.reload.slug
  end

  test "blank database slug may be set" do
    @person.update_column(:slug, nil)

    assert @person.update(slug: "pat-chosen")
    assert_equal "pat-chosen", @person.reload.slug
  end

  # --- rename_slug! -------------------------------------------------------------

  test "slug_children lists the association and every declared pair once" do
    assert_equal [
      %w[athletes person_slug],
      %w[news primary_person_slug],
      %w[news secondary_person_slug],
      %w[aliases person_slug]
    ], SluggablePerson.slug_children
  end

  test "rename_slug! moves the row and cascades to every child column" do
    other = SluggablePerson.create!(name: "Other Person")
    SluggableAthlete.create!(person_slug: "pat-passer")
    SluggableAthlete.create!(person_slug: other.slug)
    ActiveRecord::Base.connection.execute(
      "INSERT INTO news (primary_person_slug, secondary_person_slug) VALUES ('pat-passer', 'other-person'), ('other-person', 'pat-passer')"
    )
    ActiveRecord::Base.connection.execute("INSERT INTO aliases (person_slug) VALUES ('pat-passer')")

    counts = @person.rename_slug!("pat-the-passer")

    assert_equal "pat-the-passer", @person.slug
    assert_equal "pat-the-passer", @person.reload.slug
    assert_equal %w[pat-the-passer other-person], column("athletes", "person_slug")
    assert_equal %w[pat-the-passer other-person], column("news", "primary_person_slug")
    assert_equal %w[other-person pat-the-passer], column("news", "secondary_person_slug")
    assert_equal %w[pat-the-passer], column("aliases", "person_slug")
    assert_equal({ "athletes.person_slug" => 1, "news.primary_person_slug" => 1,
                   "news.secondary_person_slug" => 1, "aliases.person_slug" => 1 }, counts)
    assert_equal "other-person", other.reload.slug, "another row's slug is never touched"
  end

  test "rename_slug! to the current slug changes nothing" do
    assert_equal({}, @person.rename_slug!("pat-passer"))
  end

  test "a child that cannot take the new slug rolls the parent and every earlier child back" do
    SluggableAthlete.create!(person_slug: "pat-passer")
    ActiveRecord::Base.connection.execute("INSERT INTO aliases (person_slug) VALUES ('pat-passer'), ('pat-the-passer')")

    error = assert_raises(Sluggable::SlugRefused) { @person.rename_slug!("pat-the-passer") }

    assert_includes error.record.errors[:slug], "has already been taken"
    assert_equal "pat-passer", @person.slug, "the in-memory slug is untouched on a refusal"
    assert_equal "pat-passer", @person.reload.slug
    assert_equal %w[pat-passer], column("athletes", "person_slug"),
                 "the athletes cascade ran before the aliases conflict and must be rolled back"
  end

  test "a slug another row holds is refused before anything is written" do
    SluggablePerson.create!(name: "Pat The Passer")
    SluggableAthlete.create!(person_slug: "pat-passer")

    error = assert_raises(Sluggable::SlugRefused) { @person.rename_slug!("pat-the-passer") }

    assert_kind_of ActiveRecord::RecordInvalid, error, "callers that rescue RecordInvalid still catch it"
    assert_equal ["has already been taken"], @person.errors[:slug]
    assert_equal "pat-passer", @person.reload.slug
    assert_equal %w[pat-passer], column("athletes", "person_slug")
  end

  test "a blank or badly formed slug is refused" do
    { "" => "can't be blank", "Pat Passer" => "is invalid", "pat--passer" => "is invalid",
      "-pat" => "is invalid", "pat/../x" => "is invalid" }.each do |candidate, reason|
      error = assert_raises(Sluggable::SlugRefused, candidate.inspect) { @person.rename_slug!(candidate) }
      assert_equal [reason], error.record.errors[:slug], candidate.inspect
    end
    assert_equal "pat-passer", @person.reload.slug
  end

  test "rename_slug answers false with the reason instead of raising" do
    SluggablePerson.create!(name: "Taken")

    refute @person.rename_slug("taken")
    assert_equal ["has already been taken"], @person.errors[:slug]

    assert @person.rename_slug("pat-p")
    assert_empty @person.errors[:slug]
    assert_equal "pat-p", @person.reload.slug
  end

  test "an outer transaction that rolls back takes the rename with it" do
    SluggableAthlete.create!(person_slug: "pat-passer")

    SluggablePerson.transaction do
      @person.rename_slug!("pat-the-passer")
      raise ActiveRecord::Rollback
    end

    assert_equal "pat-passer", SluggablePerson.find(@person.id).slug
    assert_equal %w[pat-passer], column("athletes", "person_slug")
  end

  test "a model with its own slug_format accepts what the default refuses" do
    klass = Class.new(SluggablePerson) { self.slug_format = /\A[a-z0-9.@-]+\z/ }
    person = klass.find(@person.id)

    person.rename_slug!("pat-pat@example.com")

    assert_equal "pat-pat@example.com", @person.reload.slug
  end

  test "an unsaved record cannot be renamed" do
    assert_raises(ActiveRecord::RecordNotSaved) { SluggablePerson.new(name: "New").rename_slug!("new") }
  end
end
