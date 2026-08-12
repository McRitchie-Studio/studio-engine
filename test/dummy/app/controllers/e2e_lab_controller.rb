# The BROWSER LAB — the dummy host's pages that exist so a real browser can drive
# real engine partials.
#
# WHY A LAB AND NOT THE ENGINE'S OWN PAGES. The engine's shipped controllers
# (/admin/style, /error_logs, …) all inherit from a HOST-owned ApplicationController
# and sit behind require_authentication/require_admin, which need a User model, a
# users table and a session the dummy does not have. Standing that up would mean
# inventing an admin user and a login flow — fiction the lane would then rest on,
# and none of it is the thing under test.
#
# What IS under test is the engine's VIEW PARTIALS and the browser programs inside
# them. So the lab renders those partials directly, through the real Rails view
# stack, in a real layout, over real HTTP, in a real browser.
#
# THE RULE THIS CONTROLLER AND ITS VIEWS MUST KEEP: a lab page may set up a
# partial's LOCALS and nothing else. The moment a lab page reimplements what a
# partial does — hand-writing a sticky header instead of rendering
# layouts/_navbar — the spec starts grading the lab, and the lane becomes
# decoration that reports green over untested engine code. Every page renders
# engine partials BY NAME. test/lib/e2e_lane_contract_test.rb asserts that.
#
# `logged_in?`/`root_path` mirror the host controller in
# test/integration/sidebar_navbar_render_test.rb, which is this repo's established
# way to render the navbar with no session.
class E2eLabController < ActionController::Base
  # THE DUMMY'S ASSET DELIVERY — the host half of the contract, not a stub of it.
  #
  # layouts/studio/_head is the engine's real head partial and the lane needs it:
  # it installs the Alpine `theme` store the navbar's toggle reads, sets
  # `body { overflow-anchor: none }` (which the paint spec depends on — scroll
  # anchoring would otherwise drag scrollY when a bar's height changes and
  # contaminate the measurement), and publishes --nav-h/--nav-bottom.
  #
  # But its last nine lines are stylesheet_link_tag / javascript_include_tag /
  # javascript_importmap_tags: the HOST's asset pipeline, which a gem does not have
  # and has no reason to grow. Rather than fork the partial or skip it, the dummy
  # does what every host does — it delivers the assets, by its own route. e2e/boot.rb
  # copies the engine's real app/assets JS and CSS into test/dummy/public/e2e, and
  # these three helpers point at them. The engine's shipped `studio/sortable.js` is
  # the same bytes here as in a consuming app.
  #
  # Scoped to this controller (declared with `helper`, defined here rather than in
  # app/helpers) so it cannot shadow the real ActionView helpers for the view tests
  # that render engine partials through ActionView::Base.
  #
  # NAMED LIMIT: `javascript_importmap_tags` delivers Alpine and nothing else. There
  # is no Turbo in the lab, so `turbo:load`/`turbo:render` listeners never fire and
  # the lane cannot observe Turbo-navigation behavior. docs/E2E_LANE.md records it.
  module AssetDelivery
    ENGINE_STYLESHEETS = { "studio/sticky_table_header" => "/e2e/css/studio/sticky_table_header.css" }.freeze

    def stylesheet_link_tag(*sources, **options)
      links = sources.filter_map do |source|
        # "tailwind" is the compiled bundle e2e/boot.rb builds; "application" is the
        # HOST's own sheet, and the dummy host has none.
        href = source.to_s == "tailwind" ? "/e2e/tailwind.css" : ENGINE_STYLESHEETS[source.to_s]
        tag.link(rel: "stylesheet", href: href) if href
      end
      safe_join(links)
    end

    def javascript_include_tag(*sources, **options)
      scripts = sources.map do |source|
        tag.script("".html_safe, src: "/e2e/js/#{source}.js", defer: options[:defer].present?)
      end
      safe_join(scripts)
    end

    def javascript_importmap_tags(*)
      tag.script("".html_safe, src: "/e2e/alpine.js", defer: true)
    end
  end

  helper AssetDelivery

  layout "e2e_lab"

  helper_method :logged_in?, :root_path

  def logged_in? = false

  def root_path = "/"

  # DEFECT 1's page — the bar stack above the navbar.
  #
  # Renders studio/banners/_stack and layouts/_navbar as SIBLINGS, in that order,
  # which is the composition the stack partial documents. The two partials together
  # ARE the mechanism under test: the stack decides whether it publishes a measured
  # height, the navbar decides whether its `top` reads one. A spec driving this page
  # observes the contract between them the only way it can be observed — by watching
  # where the header actually paints, frame by frame.
  #
  # The environment banner gates the stack and Studio.show_environment_banner? is
  # true in every environment except production, so running the lab under
  # RAILS_ENV=test renders a real bar with no stubbing at all.
  def bar_stack = render(:bar_stack)

  # DEFECT 3's page — the @-time localiser script.
  #
  # Renders studio/_at_time_script plus stamps for it to localise. The script is the
  # subject; the stamps are what prove it ran.
  def at_time = render(:at_time)

  # Liveness. Playwright's webServer polls this before the first spec, so it must
  # not depend on anything a lab page needs.
  def up = render(plain: "ok")
end
