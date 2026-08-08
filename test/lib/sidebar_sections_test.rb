# frozen_string_literal: true

require "test_helper"

# Resolution rules for Studio.sidebar_sections (lib/studio/sidebar_sections.rb):
# static arrays pass through symbolized, callables receive the view context,
# and admin-flagged sections resolve only for admin? viewers — including views
# that expose no admin? at all (bare contexts count as non-admin).
class SidebarSectionsTest < Minitest::Test
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
