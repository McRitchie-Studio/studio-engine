# frozen_string_literal: true

require "test_helper"
require "stringio"

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
  # Shaped like a consumer that has every standard column, so the defaults all
  # resolve and the PAGE split is what the assertions are actually measuring.
  FullUser = Struct.new(:first_name) do
    def avatar = nil
    def last_name = nil
    def email = "pat@example.com"
    def provider = "google_oauth2"
    def uid = "1"
    def birth_day = nil
    def birth_month = nil
    def birth_year = nil
  end
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

    assert_equal %i[google name email birthday], resolved.map { |s| s[:key] }
  end

  # --- the page split ----------------------------------------------------------
  #
  # /profile is "you at a glance" and /profile/edit is the form. A row says which
  # it belongs to; `page:` on resolve selects one, and nil means all of them —
  # which is what the write guards ask, since a field is writable if its row
  # exists on either page.

  def test_resolving_a_page_returns_only_that_pages_rows
    assert_equal %i[google], Studio::ProfileSections.resolve(nil, full_view, page: :show).map { |s| s[:key] }
    assert_equal %i[name email birthday], Studio::ProfileSections.resolve(nil, full_view, page: :edit).map { |s| s[:key] }
  end

  def test_no_page_returns_every_row
    assert_equal 4, Studio::ProfileSections.resolve(nil, full_view).length
  end

  # A row that never says defaults to :edit — someone adding a row is usually
  # adding a field, and the read page is a deliberate, curated surface.
  def test_a_row_that_names_no_page_is_an_edit_row
    section = { key: :custom, partial: "x" }

    assert_equal %i[custom], Studio::ProfileSections.resolve([section], full_view, page: :edit).map { |s| s[:key] }
    assert_equal [], Studio::ProfileSections.resolve([section], full_view, page: :show).map { |s| s[:key] }
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
    # mcritchie-industries' shape: an email column and none of the rest.
    partial_user = Struct.new(:x) { def email = "pat@example.com" }.new(nil)
    resolved = Studio::ProfileSections.resolve(nil, UserView.new(partial_user))

    assert_equal %i[email], resolved.map { |s| s[:key] },
      "email is served, the name and birthday rows are not — the page keeps the half it can render"
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

    assert_equal %i[google name email birthday wallet], resolved.map { |s| s[:key] }
  end

  def test_hosts_drop_a_standard_row_by_key
    config = Studio::ProfileSections.defaults.reject { |s| s[:key] == :birthday }
    resolved = Studio::ProfileSections.resolve(config, full_view)

    assert_equal %i[google name email], resolved.map { |s| s[:key] }
  end

  # --- the Studio.* facade -----------------------------------------------------

  def test_studio_profile_sections_for_reads_the_module_config
    Studio.profile_sections = [{ key: :only, partial: "x" }]

    assert_equal %i[only], Studio.profile_sections_for(full_view).map { |s| s[:key] }
  ensure
    Studio.profile_sections = nil
  end

  def test_studio_default_profile_sections_is_the_public_composition_handle
    assert_equal %i[google newsletter name email birthday], Studio.default_profile_sections.map { |s| s[:key] }
  end

  # --- the app-capability gate (`if:`) ----------------------------------------
  #
  # DISTINCT FROM `requires:`, and the distinction is the bug this closes.
  # `requires:` asks whether the MODEL can serve the row; `if:` asks whether the
  # APP offers the feature. Every consumer's users table carries provider and
  # uid, so the model gate alone selected the whole fleet for the Google row —
  # including mcritchie-industries, which has `auth_methods = %i[magic_link]` and
  # no omniauth gem, and would have rendered a Connect button leading nowhere.

  def test_a_row_whose_if_returns_false_is_dropped
    sections = [{ key: :on, partial: "x", if: -> { true } },
                { key: :off, partial: "x", if: -> { false } }]

    assert_equal %i[on], Studio::ProfileSections.resolve(sections, full_view).map { |s| s[:key] }
  end

  def test_an_if_taking_the_view_receives_it
    sections = [{ key: :named, partial: "x", if: ->(view) { view.current_user.first_name == "Alex" } }]

    assert_equal %i[named], Studio::ProfileSections.resolve(sections, full_view).map { |s| s[:key] }
  end

  # REGRESSION GUARD. `if: :method_name` is Rails' own before_action spelling and
  # the most natural thing a host will write. A Symbol does not answer `call`, so
  # it used to be coerced straight to true — a gate that silently did nothing,
  # failing in the same permissive direction as the bug `if:` exists to fix.
  def test_a_symbol_if_calls_the_view_rather_than_coercing_to_true
    view = Struct.new(:current_user) do
      def admin? = false
      def never? = false
      def always? = true
    end.new(nil)

    assert_equal [], Studio::ProfileSections.resolve([{ key: :s, partial: "x", if: :never? }], view).map { |s| s[:key] }
    assert_equal %i[s], Studio::ProfileSections.resolve([{ key: :s, partial: "x", if: :always? }], view).map { |s| s[:key] }
    assert_equal [], Studio::ProfileSections.resolve([{ key: :s, partial: "x", if: "never?" }], view).map { |s| s[:key] }
  end

  # An `if:` naming a method the view does not have is a typo. Dropping the row
  # keeps the failure in the safe direction — a missing row is visible and
  # fixable; a row that renders because its gate was misspelled is the bug.
  def test_a_symbol_if_naming_a_missing_method_drops_the_row
    view = Struct.new(:current_user) { def admin? = false }.new(nil)

    assert_equal [], Studio::ProfileSections.resolve([{ key: :s, partial: "x", if: :typo? }], view).map { |s| s[:key] }
  end

  # Carl's F1 on #130: the Symbol branch was arity-0 only, so a predicate written
  # as `def visible?(view)` raised ArgumentError — a 500 on /profile rather than a
  # dropped row — while the lambda branch three lines below accepted both shapes.
  def test_a_symbol_if_accepts_a_predicate_that_takes_the_view
    view = Struct.new(:current_user) do
      def admin? = false
      def wants?(v) = !v.nil?
    end.new(:someone)

    assert_equal %i[s], Studio::ProfileSections.resolve([{ key: :s, partial: "x", if: :wants? }], view).map { |s| s[:key] }
  end

  # Carl's F2 on #130: dropping silently repeats the shape of the bug this key
  # was added to fix. The host gets told.
  def test_a_gate_naming_a_missing_method_warns
    # No stub: this suite boots no Rails, so warn_gate takes its Kernel.warn
    # fallback and the real path can be captured. (Minitest 6 dropped
    # minitest/mock, so a stub would have had to be hand-rolled anyway.)
    view = Struct.new(:current_user) { def admin? = false }.new(nil)
    captured = StringIO.new
    original, $stderr = $stderr, captured
    begin
      Studio::ProfileSections.resolve([{ key: :s, partial: "x", if: :typo? }], view)
    ensure
      $stderr = original
    end

    assert_includes captured.string, "typo?", "a typo'd gate must say so"
  end

  def test_a_row_with_no_if_always_renders
    assert_equal %i[bare], Studio::ProfileSections.resolve([{ key: :bare, partial: "x" }], full_view).map { |s| s[:key] }
  end

  # REGRESSION GUARD for the blocker itself. mcritchie-industries' shape: the
  # columns are present, the auth method is not.
  def test_the_google_row_drops_in_an_app_that_does_not_offer_google
    oauth_user = Struct.new(:first_name, :provider, :uid) { def avatar = nil }.new("Alex", "google_oauth2", "1")
    view = UserView.new(oauth_user)

    Studio.auth_methods = %i[magic_link]
    refute_includes Studio::ProfileSections.resolve(nil, view).map { |s| s[:key] }, :google,
      "having provider/uid columns is not the same as offering Google sign-in"

    Studio.auth_methods = %i[magic_link google]
    assert_includes Studio::ProfileSections.resolve(nil, view).map { |s| s[:key] }, :google
  ensure
    Studio.auth_methods = %i[magic_link google wallet]
  end

  # The requires-gate, exercised on the row most likely to be absent: the Google
  # row needs BOTH provider and uid, and a host with neither must get a page
  # without it rather than a NoMethodError from the partial's linked? check.
  def test_the_google_row_drops_for_a_model_with_no_oauth_columns
    bare = Struct.new(:first_name).new("Alex")

    refute_includes Studio::ProfileSections.resolve(nil, UserView.new(bare)).map { |s| s[:key] }, :google,
      "a model answering neither provider nor uid cannot serve the Google row"
    assert_includes Studio::ProfileSections.resolve(nil, full_view).map { |s| s[:key] }, :google
  end

  def test_default_config_is_nil_so_a_bare_app_gets_the_standard_page
    assert_nil Studio.profile_sections,
      "the shipped default must be nil (= standard page), not [] (= blank page)"
  end
end
