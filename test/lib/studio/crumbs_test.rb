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

  def test_the_root_page_matches_the_root_address
    @crumbs.page :home, "Home", "/"
    assert_equal :home, @crumbs.key_for_path(@view, "/")
    assert_equal :home, @crumbs.key_for_path(@view, "")
    assert_equal :deployments, @crumbs.key_for_path(@view, "/deployments")
  end

  def with_map
    original = Studio.instance_variable_get(:@crumbs)
    Studio.instance_variable_set(:@crumbs, @crumbs)
    yield View.new.extend(Studio::CrumbsHelper)
  ensure
    Studio.instance_variable_set(:@crumbs, original)
  end

  def stub_singleton(object, name, value)
    original = object.method(name)
    object.define_singleton_method(name) { |*args| value.respond_to?(:call) ? value.call(*args) : value }
    yield
  ensure
    object.define_singleton_method(name, original) if original
  end

  def test_an_unknown_key_raises_in_development_and_test
    with_map do |view|
      stub_singleton(Studio::Crumbs, :strict?, true) do
        assert_raises(Studio::Crumbs::UnknownPage) { view.studio_crumbs(:nowhere) }
        assert_raises(Studio::Crumbs::UnknownPage) { view.studio_crumbs(parent: :nowhere) }
      end
    end
  end

  def test_an_unknown_key_in_production_is_logged_and_draws_no_trail
    reported = []
    with_map do |view|
      stub_singleton(Studio::Crumbs, :strict?, false) do
        stub_singleton(Studio::Crumbs, :report, ->(error) { reported << error }) do
          assert_equal [], view.studio_crumbs(:nowhere)
          assert_equal [], view.studio_crumbs(parent: :nowhere)
          assert_equal [{ label: "Admin", href: "/admin/dashboard" }], view.studio_crumbs(:deployments),
                       "a known key still draws its trail"
        end
      end
    end
    assert_equal [Studio::Crumbs::UnknownPage] * 2, reported.map(&:class)
  end

  def test_strict_follows_the_rails_env
    env = Struct.new(:name) do
      def development? = name == "development"
      def test? = name == "test"
    end
    assert Studio::Crumbs.strict?(env.new("development"))
    assert Studio::Crumbs.strict?(env.new("test"))
    refute Studio::Crumbs.strict?(env.new("production"))
    refute Studio::Crumbs.strict?(env.new("staging"))
  end

  def test_a_report_goes_to_the_error_log
    captured = []
    log = Module.new
    log.define_singleton_method(:capture!) { |error| captured << error }
    had = defined?(::ErrorLog)
    original = (::ErrorLog if had)
    Object.send(:remove_const, :ErrorLog) if had
    Object.const_set(:ErrorLog, log)
    error = Studio::Crumbs::UnknownPage.new("Studio.crumbs has no page :report_once_#{rand(1 << 30)}")
    Studio::Crumbs.report(error)
    Studio::Crumbs.report(error)
    assert_equal [error], captured, "once per message: a layout renders on every request"
  ensure
    Object.send(:remove_const, :ErrorLog) if defined?(::ErrorLog)
    Object.const_set(:ErrorLog, original) if had
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
