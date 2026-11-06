# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/studio/crumbs"
require_relative "../../../app/helpers/studio/crumbs_helper"

# [unit] Studio::Crumbs: one parent map, and the trail builds itself up the chain.
class StudioCrumbsTest < Minitest::Test
  # A stand-in for a view: route helpers on itself, others on main_app.
  class View
    Release = Struct.new(:slug)

    def admin_dashboard_path = "/admin/dashboard"
    def deployments_path = "/deployments"
    def release_path(release) = "/deployments/#{release.slug}"

    def main_app = MainApp.new

    class MainApp
      def epics_path = "/epics"
    end
  end

  def setup
    @crumbs = Studio::Crumbs.new.draw do
      page :admin, "Admin", :admin_dashboard_path
      page :deployments, "Deployments", :deployments_path, parent: :admin
      page :release, ->(release:) { release.slug }, ->(release:) { release_path(release) }, parent: :deployments
      page :epics, "Epics", :epics_path, parent: :deployments
      page :docs, "Docs", "/docs"
    end
    @view = View.new
  end

  def test_the_map_page_gets_its_ancestors_root_first_and_not_itself
    assert_equal [{ label: "Admin", href: "/admin/dashboard" }], @crumbs.trail(@view, :deployments)
    assert_equal [], @crumbs.trail(@view, :admin)
  end

  def test_a_page_outside_the_map_names_only_its_parent
    assert_equal [{ label: "Admin", href: "/admin/dashboard" }, { label: "Deployments", href: "/deployments" }],
                 @crumbs.trail(@view, parent: :deployments)
  end

  def test_lambdas_take_the_page_keywords_and_run_in_the_view
    release = View::Release.new("rel-20261105-9199b4")
    trail = @crumbs.trail(@view, parent: :release, release: release, unused: 1)

    assert_equal %w[Admin Deployments rel-20261105-9199b4], trail.map { |crumb| crumb[:label] }
    assert_equal "/deployments/rel-20261105-9199b4", trail.last[:href]
  end

  def test_a_route_the_view_lacks_is_read_on_main_app_and_a_string_stands
    assert_equal "/epics", @crumbs.trail(@view, parent: :epics).last[:href]
    assert_equal "/docs", @crumbs.trail(@view, parent: :docs).last[:href]
  end

  def test_an_unknown_page_or_a_loop_fails_loudly
    assert_raises(Studio::Crumbs::UnknownPage) { @crumbs.trail(@view, parent: :nowhere) }
    @crumbs.page :a, "A", "/a", parent: :b
    @crumbs.page :b, "B", "/b", parent: :a
    assert_raises(Studio::Crumbs::Cycle) { @crumbs.trail(@view, :a) }
  end

  def test_naming_the_page_and_its_parent_at_once_is_refused
    assert_raises(ArgumentError) { @crumbs.trail(@view, :deployments, parent: :admin) }
  end

  def test_the_app_has_one_map
    assert_same Studio.crumbs, Studio.crumbs
    assert_kind_of Studio::Crumbs, Studio.crumbs
  end

  # An engine page (the style guide) cannot know the host's key for itself.
  def test_a_page_is_found_by_its_address_and_a_lambda_that_needs_keywords_never_matches
    assert_equal :deployments, @crumbs.key_for_path(@view, "/deployments")
    assert_equal :deployments, @crumbs.key_for_path(@view, "/deployments/")
    assert_equal :docs, @crumbs.key_for_path(@view, "/docs")
    assert_nil @crumbs.key_for_path(@view, "/deployments/rel-1")
    assert_nil @crumbs.key_for_path(@view, "/nowhere")
  end

  def test_studio_crumbs_here_reads_the_app_map_at_this_address_and_is_empty_off_it
    view = View.new.extend(Studio::CrumbsHelper)
    request = Struct.new(:path)
    original = Studio.instance_variable_get(:@crumbs)
    Studio.instance_variable_set(:@crumbs, @crumbs)
    view.define_singleton_method(:request) { request.new("/deployments") }
    assert_equal [{ label: "Admin", href: "/admin/dashboard" }], view.studio_crumbs_here
    view.define_singleton_method(:request) { request.new("/admin/style") }
    assert_equal [], view.studio_crumbs_here
    view.define_singleton_method(:request) { nil }
    assert_equal [], view.studio_crumbs_here
  ensure
    Studio.instance_variable_set(:@crumbs, original)
  end
end
