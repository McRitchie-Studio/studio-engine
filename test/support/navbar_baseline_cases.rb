# frozen_string_literal: true

# The navbar baseline: renders of layouts/_navbar, components/_user_nav,
# components/_sidebar_panel and components/_link_sidebar that touch ONLY
# settings 0.113.0 already had. Captured from v0.113.0 into
# test/fixtures/files/navbar_unset_baseline, and held by
# test/integration/navbar_unset_baseline_test.rb: with every navbar setting
# added since left unset (or set to its default), the engine renders these
# bytes exactly.
#
# REGENERATING. Only for a DELIBERATE change to what an unset navbar renders,
# and say so in the CHANGELOG. From a checkout of the tree to capture
# (git archive <ref> | tar -x -C <dir>), with that tree's own Gemfile:
#
#   BUNDLE_GEMFILE=<dir>/Gemfile ruby test/support/navbar_baseline_cases.rb <dir> \
#     test/fixtures/files/navbar_unset_baseline
#
# It requires the target tree's dummy app, so the bytes are that tree's.
module NavbarBaselineCases
  SECTIONS = [{ title: "Site", links: [{ label: "Home", href: "/", emoji: "*" }] }].freeze

  # name => [signed_in, admin, settings, template]. settings are 0.113.0's own.
  CASES = {
    "navbar-out-live" => [false, false, {}, %(<%= render "layouts/navbar" %>)],
    "navbar-out-preview" => [false, false, {}, %(<%= render "layouts/navbar", preview: true %>)],
    "navbar-in-live" => [true, false, {}, %(<%= render "layouts/navbar" %>)],
    "navbar-in-preview" => [true, false, {}, %(<%= render "layouts/navbar", preview: true %>)],
    "navbar-admin-live" => [true, true, {}, %(<%= render "layouts/navbar" %>)],
    "navbar-admin-preview" => [true, true, {}, %(<%= render "layouts/navbar", preview: true %>)],
    "navbar-in-sidebar-live" => [true, false, { sidebar_sections: SECTIONS }, %(<%= render "layouts/navbar" %>)],
    "navbar-out-sidebar-live" => [false, false, { sidebar_sections: SECTIONS }, %(<%= render "layouts/navbar" %>)],
    "navbar-in-timeline-live" => [true, false, { navbar_scroll_timeline: true }, %(<%= render "layouts/navbar" %>)],
    "navbar-out-cta-live" => [false, false, { navbar_signed_out_cta: { label: "Build App", path: "/build" } },
                              %(<%= render "layouts/navbar" %>)],
    "navbar-in-items-live" => [true, false, { navbar_items: ["navbar_slot_fixtures/geo"] }, %(<%= render "layouts/navbar" %>)],
    "navbar-in-balance-live" => [true, false, {}, %(<%= render "layouts/navbar", balance_html: "<b>$5</b>".html_safe %>)],
    "navbar-logo-in-live" => [true, false, { app_name: "Turf Monster", theme_logos: [{ file: "logo.png", title: "Navbar Logo" }] },
                              %(<%= render "layouts/navbar" %>)],
    "navbar-logo-out-preview-div" => [false, false, { app_name: "Turf Monster", theme_logos: [{ file: "logo.png", title: "Navbar Logo" }] },
                                      %(<%= render "layouts/navbar", preview: true, brand_heading: false %>)],
    "user_nav-plain" => [true, false, {}, %(<%= render "components/user_nav" %>)],
    "user_nav-div2slot" => [true, false, {}, %(<%= render "components/user_nav", div2_slot: "navbar_slot_fixtures/geo" %>)],
    "panel-full" => [false, false, {}, %(<%= render "components/sidebar_panel", id: "p", title: "Menu", open: "o", ) +
                                       %(actions_html: "<i>a</i>".html_safe, body_html: "<p>b</p>".html_safe, ) +
                                       %(footer_html: "<p>f</p>".html_safe, close_action: "o = false", ) +
                                       %(outside_action: "o = false", escape_action: "o = false" %>)],
    "panel-noid-close" => [false, false, {}, %(<%= render "components/sidebar_panel", open: "o", close_action: "o = false", aria_label: "Gear" %>)],
    "link_sidebar" => [true, false, { sidebar_sections: SECTIONS }, %(<%= render "components/link_sidebar" %>)]
  }.freeze

  # The host every case renders through: signed in or out, admin or not, with
  # the test view fixtures on the path.
  def self.host_class
    @host_class ||= Class.new(ActionController::Base) do
      prepend_view_path File.expand_path("../views/fixtures", __dir__)
      helper_method :logged_in?, :current_user, :root_path, :profile_path, :admin?
      cattr_accessor :signed_in, :admin

      def logged_in? = !!self.class.signed_in
      def current_user = (self.class.signed_in ? (@current_user ||= NavbarBaselineCases.stub_user.new) : nil)
      def admin? = !!(self.class.signed_in && self.class.admin)
      def root_path = "/"
      def profile_path = "/profile"
    end
  end

  def self.stub_user
    @stub_user ||= Class.new do
      def display_name = "Plain User"
      def first_name = "Plain"
      def admin? = false
      def avatar = @avatar ||= Class.new { def attached? = false }.new
      def avatar_color = "#0ea5e9"
      def avatar_initials = "PU"
    end
  end

  # Renders one case with its settings applied, restoring them after.
  def self.render(name)
    signed_in, admin, settings, template = CASES.fetch(name)
    prior = settings.keys.to_h { |key| [key, Studio.public_send(key)] }
    settings.each { |key, value| Studio.public_send(:"#{key}=", value) }
    host = host_class
    host.signed_in = signed_in
    host.admin = admin
    controller = host.new
    controller.request = ActionDispatch::TestRequest.create("PATH_INFO" => "/")
    controller.response = ActionDispatch::TestResponse.new
    controller.render_to_string(inline: template)
  ensure
    prior&.each { |key, value| Studio.public_send(:"#{key}=", value) }
  end
end

if $PROGRAM_NAME == __FILE__
  root, out = ARGV.fetch(0), ARGV.fetch(1)
  out = File.expand_path(out)
  Dir.chdir(root)
  ENV["RAILS_ENV"] = "test"
  require "bundler/setup"
  require File.join(root, "test/dummy/config/environment")
  require "fileutils"
  FileUtils.mkdir_p(out)
  NavbarBaselineCases::CASES.each_key do |name|
    File.write(File.join(out, "#{name}.html"), NavbarBaselineCases.render(name))
  end
  puts "#{NavbarBaselineCases::CASES.size} baseline renders -> #{out}"
end
