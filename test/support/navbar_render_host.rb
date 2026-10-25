# frozen_string_literal: true

# A host controller for rendering the engine navbar and user nav through the
# dummy app, signed in or out, with the test view fixtures on the path. Shared
# by the render tests for the navbar settings added after 0.113.0.
class NavbarRenderHost < ActionController::Base
  prepend_view_path File.expand_path("../views/fixtures", __dir__)
  helper_method :logged_in?, :current_user, :root_path, :profile_path, :admin_label

  class StubUser
    def display_name = "Plain User"
    def admin? = false
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#0ea5e9"
    def avatar_initials = "PU"
  end

  cattr_accessor :signed_in, default: false

  def logged_in? = self.class.signed_in
  def current_user = (self.class.signed_in ? (@current_user ||= StubUser.new) : nil)
  def root_path = "/"
  def profile_path = "/profile"
  def admin_label = "Settings"

  # Renders an inline ERB template the way a page would, and returns the HTML.
  def self.render_inline(template, signed_in: false)
    self.signed_in = signed_in
    controller = new
    controller.request = ActionDispatch::TestRequest.create("PATH_INFO" => "/")
    controller.response = ActionDispatch::TestResponse.new
    controller.render_to_string(inline: template)
  ensure
    self.signed_in = false
  end

  # The engine navbar, with optional locals written as Ruby source.
  def self.render_navbar(signed_in: false, locals: nil)
    render_inline(%(<%= render "layouts/navbar"#{", #{locals}" if locals} %>), signed_in: signed_in)
  end
end
