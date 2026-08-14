# frozen_string_literal: true

require "test_helper"

# [unit] Resolution rules for Studio.profile_sections (lib/studio/profile_sections.rb).
#
# The rules that matter, and why each is here rather than assumed:
#
#   1. A nil config resolves to the STANDARD PAGE, not to nothing. This is what
#      makes a brand-new app's profile page work with an empty initializer, and
#      it is the one rule a "reasonable" refactor would invert.
#   2. A row is dropped when this host's user model cannot serve it. The three
#      consuming apps genuinely disagree about their users table
#      (mcritchie-industries has no first_name), and a shared page that assumed
#      the column would raise NoMethodError on every signed-in request there.
#   3. Everything the sidebar's resolver already guarantees — array or callable,
#      symbolized, admin rows gated — because this registry deliberately copies
#      that shape and a divergence would be a surprise.
class ProfileSectionsTest < Minitest::Test
  # View doubles. `current_user` is what the requires-gate reads; a bare view
  # (no current_user, no admin?) stands in for a render with nobody signed in.
  FullUser  = Struct.new(:first_name) { def avatar = nil }
  ThinUser  = Struct.new(:nothing)

  AdminView = Struct.new(:current_user) { def admin? = true }
  UserView  = Struct.new(:current_user) { def admin? = false }
  BareView  = Struct.new(:name)

  def full_view(admin: false)
    (admin ? AdminView : UserView).new(FullUser.new("Alex"))
  end

  def thin_view
    UserView.new(ThinUser.new(nil))
  end

  # --- 1. nil means the standard page ----------------------------------------

  # THE LOAD-BEARING DEFAULT. `nil` must mean "give me the engine's page", not
  # "I declared no rows". Flip this and every app with an empty initializer gets
  # a blank profile page — which is precisely the thing standardizing it was
  # meant to prevent.
  def test_nil_config_resolves_to_the_default_sections
    resolved = Studio::ProfileSections.resolve(nil, full_view)

    assert_equal %i[avatar first_name], resolved.map { |s| s[:key] }
  end

  def test_an_explicitly_empty_array_still_means_no_rows
    # Distinct from nil on purpose: a host that genuinely wants no page says so.
    assert_equal [], Studio::ProfileSections.resolve([], full_view)
  end

  def test_defaults_are_a_fresh_mutable_copy_each_call
    first = Studio::ProfileSections.defaults
    first.first[:title] = "MUTATED"

    refute_equal "MUTATED", Studio::ProfileSections.defaults.first[:title],
      "handing out the frozen literal lets one host's edit leak into the next render"
  end

  # --- 2. rows drop when the host cannot serve them ---------------------------

  # REGRESSION GUARD for the actual shape of the ecosystem: mcritchie-industries'
  # users table has eight columns and no first_name. The name row must vanish
  # there, silently, rather than raising on every visit to /profile.
  def test_rows_requiring_a_missing_attribute_are_dropped
    resolved = Studio::ProfileSections.resolve(nil, thin_view)

    assert_equal [], resolved.map { |s| s[:key] },
      "a user model answering neither avatar nor first_name serves no default row"
  end

  def test_rows_the_host_can_serve_survive_alongside_ones_it_cannot
    partial_user = Struct.new(:x) { def avatar = nil }.new(nil)
    resolved = Studio::ProfileSections.resolve(nil, UserView.new(partial_user))

    assert_equal %i[avatar], resolved.map { |s| s[:key] },
      "avatar is served, first_name is not — the page keeps the half it can render"
  end

  def test_a_row_requiring_nothing_always_renders
    section = { key: :explainer, title: "About", partial: "x" }

    assert_equal %i[explainer],
      Studio::ProfileSections.resolve([section], thin_view).map { |s| s[:key] }
  end

  def test_a_row_may_require_several_attributes_at_once
    section = { key: :both, partial: "x", requires: %i[avatar first_name] }

    assert_equal %i[both], Studio::ProfileSections.resolve([section], full_view).map { |s| s[:key] }
    assert_equal [],       Studio::ProfileSections.resolve([section], thin_view).map { |s| s[:key] }
  end

  def test_no_current_user_serves_no_requiring_row
    # A view rendering for nobody: requirements cannot be checked, so a row that
    # reads the user is not rendered. Guessing "probably fine" here is how a
    # signed-out render raises.
    resolved = Studio::ProfileSections.resolve(nil, BareView.new("x"))

    assert_equal [], resolved.map { |s| s[:key] }
  end

  # --- 3. the sidebar's guarantees, kept ---------------------------------------

  def test_string_keys_symbolize
    section = { "key" => "avatar", "title" => "Photo", "partial" => "x" }
    resolved = Studio::ProfileSections.resolve([section], full_view).first

    assert_equal :avatar, resolved[:key]
    assert_equal "Photo", resolved[:title]
  end

  def test_callable_config_receives_the_view_context
    config = ->(view) { [{ key: :who, title: "For #{view.current_user.first_name}", partial: "x" }] }
    resolved = Studio::ProfileSections.resolve(config, full_view)

    assert_equal "For Alex", resolved.first[:title]
  end

  def test_admin_rows_drop_for_non_admin_viewers
    sections = [{ key: :ops, partial: "x", admin: true }, { key: :open, partial: "x" }]

    assert_equal %i[ops open], Studio::ProfileSections.resolve(sections, full_view(admin: true)).map { |s| s[:key] }
    assert_equal %i[open],     Studio::ProfileSections.resolve(sections, full_view).map { |s| s[:key] }
  end

  def test_declared_order_is_preserved
    sections = [{ key: :c, partial: "x" }, { key: :a, partial: "x" }, { key: :b, partial: "x" }]

    assert_equal %i[c a b], Studio::ProfileSections.resolve(sections, full_view).map { |s| s[:key] },
      "hosts compose with + and expect their rows where they put them"
  end

  # --- the host-composition seam ----------------------------------------------

  # The documented way a host customizes: compose against the defaults so a later
  # engine release that adds a standard row delivers it. Asserted because the
  # comment in lib/studio.rb tells hosts to write exactly this.
  def test_hosts_compose_against_the_defaults
    config = ->(_view) { Studio::ProfileSections.defaults + [{ key: :wallet, partial: "x" }] }
    resolved = Studio::ProfileSections.resolve(config, full_view)

    assert_equal %i[avatar first_name wallet], resolved.map { |s| s[:key] }
  end

  def test_hosts_drop_a_standard_row_by_key
    config = Studio::ProfileSections.defaults.reject { |s| s[:key] == :avatar }
    resolved = Studio::ProfileSections.resolve(config, full_view)

    assert_equal %i[first_name], resolved.map { |s| s[:key] }
  end

  # --- the Studio.* facade -----------------------------------------------------

  def test_studio_profile_sections_for_reads_the_module_config
    Studio.profile_sections = [{ key: :only, partial: "x" }]

    assert_equal %i[only], Studio.profile_sections_for(full_view).map { |s| s[:key] }
  ensure
    Studio.profile_sections = nil
  end

  def test_studio_default_profile_sections_is_the_public_composition_handle
    assert_equal %i[avatar first_name], Studio.default_profile_sections.map { |s| s[:key] }
  end

  def test_default_config_is_nil_so_a_bare_app_gets_the_standard_page
    assert_nil Studio.profile_sections,
      "the shipped default must be nil (= standard page), not [] (= blank page)"
  end
end
