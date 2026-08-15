# frozen_string_literal: true

require "test_helper"

# Resolution rules for Studio.sidebar_sections (lib/studio/sidebar_sections.rb):
# static arrays pass through symbolized, callables receive the view context,
# and admin-flagged sections resolve only for admin? viewers — including views
# that expose no admin? at all (bare contexts count as non-admin).
class SidebarSectionsTest < Minitest::Test
  # Views that can serve the standard Profile link: signed in, with the helper.
  ProfileView = Struct.new(:name) do
    def admin? = false
    def logged_in? = true
    def profile_path = "/profile"
  end
  SignedOutView = Struct.new(:name) do
    def admin? = false
    def logged_in? = false
    def profile_path = "/profile"
  end

  AdminView    = Struct.new(:name) { def admin? = true }
  ViewerView   = Struct.new(:name) { def admin? = false }
  BareView     = Struct.new(:name)

  SECTIONS = [
    { "title" => "Site", "links" => [{ "label" => "Home", "href" => "/", "emoji" => "🏠" }] },
    { title: "Ops", admin: true, links: [{ label: "Errors", href: "/error_logs", emoji: "🚨" }] }
  ].freeze

  def test_default_config_resolves_empty
    assert_equal [], Studio.sidebar_sections_for(BareView.new("x"))
  end

  def test_static_sections_symbolize_keys_on_sections_and_links
    resolved = Studio::SidebarSections.resolve(SECTIONS, AdminView.new("a"))

    assert_equal %w[Site Ops], resolved.map { |s| s[:title] }
    assert_equal "/", resolved.first[:links].first[:href]
    assert_equal "Errors", resolved.last[:links].first[:label]
  end

  def test_admin_sections_drop_for_non_admin_viewers
    resolved = Studio::SidebarSections.resolve(SECTIONS, ViewerView.new("v"))

    assert_equal %w[Site], resolved.map { |s| s[:title] }
  end

  def test_views_without_admin_predicate_count_as_non_admin
    resolved = Studio::SidebarSections.resolve(SECTIONS, BareView.new("b"))

    assert_equal %w[Site], resolved.map { |s| s[:title] }
  end

  def test_callable_config_receives_the_view_context
    config = ->(view) { [{ title: "For #{view.name}", links: [] }] }
    resolved = Studio::SidebarSections.resolve(config, BareView.new("carl"))

    assert_equal "For carl", resolved.first[:title]
    assert_equal [], resolved.first[:links]
  end

  def test_nil_and_sectionless_configs_resolve_empty
    assert_equal [], Studio::SidebarSections.resolve(nil, BareView.new("x"))
    assert_equal [], Studio::SidebarSections.resolve([], BareView.new("x"))
    assert_equal [], Studio::SidebarSections.resolve(->(_) {}, BareView.new("x"))
  end

  def test_sections_without_links_normalize_to_empty_links
    resolved = Studio::SidebarSections.resolve([{ title: "Empty" }], BareView.new("x"))

    assert_equal [], resolved.first[:links]
  end
end

# --- the engine's own standard section ----------------------------------------
#
# The engine ships /profile, so it ships the way in — otherwise five consumers
# each declare the same entry and they drift in wording and emoji.
class SidebarStandardSectionTest < Minitest::Test
  ProfileView = Struct.new(:name) do
    def admin? = false
    def logged_in? = true
    def profile_path = "/profile"
  end

  SignedOutView = Struct.new(:name) do
    def admin? = false
    def logged_in? = false
    def profile_path = "/profile"
  end

  BareView = Struct.new(:name)

  def teardown
    Studio.draw_profile_routes = true
  end

  def resolve(view, declared = [])
    Studio::SidebarSections.resolve(declared, view)
  end

  def test_the_profile_link_leads_the_sidebar
    sections = resolve(ProfileView.new("pat"))

    assert_equal "You", sections.first[:title]
    link = sections.first[:links].first
    assert_equal "Profile", link[:label]
    assert_equal "/profile", link[:href]
  end

  # PREPENDED: it is the viewer's own account, and the operator asked for it at
  # the top. A host's sections keep their order below it.
  def test_a_hosts_sections_follow_it_in_their_own_order
    declared = [{ title: "Site", links: [] }, { title: "Ops", links: [] }]

    assert_equal %w[You Site Ops], resolve(ProfileView.new("pat"), declared).map { |s| s[:title] }
  end

  # An app that turned the page off must not be handed a menu item pointing at a
  # route that does not exist — a 404 from its own navigation.
  def test_it_is_absent_when_the_page_is_not_drawn
    Studio.draw_profile_routes = false

    assert_equal [], resolve(ProfileView.new("pat")).map { |s| s[:title] }
  end

  # /profile requires authentication, so offering it to a signed-out visitor
  # bounces them to login from something that looked like navigation.
  def test_it_is_absent_for_a_signed_out_viewer
    assert_equal [], resolve(SignedOutView.new("pat")).map { |s| s[:title] }
  end

  # A view answering neither predicate gets nothing. Safe direction: a missing
  # link is visible and fixable, a link to nowhere is the bug.
  def test_a_view_without_the_helpers_gets_nothing_rather_than_a_broken_link
    assert_equal [], resolve(BareView.new("x")).map { |s| s[:title] }
  end

  # The sidebar now has content in every signed-in app, so studio_sidebar? is
  # true where it used to depend on the host declaring something. Asserted so
  # the consequence is deliberate rather than discovered.
  def test_a_host_declaring_nothing_still_gets_a_sidebar
    refute_empty resolve(ProfileView.new("pat"), [])
  end
end
