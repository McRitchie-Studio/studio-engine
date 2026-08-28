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
  # NAMED LIMIT: `javascript_importmap_tags` delivers NOTHING (Alpine now ships in the
  # engine and arrives through javascript_include_tag, like every other engine asset).
  # There is no Turbo in the lab, so `turbo:load`/`turbo:render` listeners never fire
  # and the lane cannot observe Turbo-navigation behavior. docs/E2E_LANE.md records it.
  # Where the lab visitor is standing. A host supplies these from
  # Studio::GeoDetection; the lab supplies them as locals-of-the-page, which is
  # the same relationship every other lab page has to its partial.
  LAB_COUNTRY = "US"
  LAB_SUBDIVISION = "CO"

  module AssetDelivery
    ENGINE_STYLESHEETS = { "studio/sticky_table_header" => "/e2e/css/studio/sticky_table_header.css" }.freeze

    # The head's @font-face and preload address Montserrat by LOGICAL path through
    # asset_path, which is the host pipeline's job like the tags below. Without this
    # the dummy's plain ActionView asset_path returns "/studio/montserrat-latin.woff2"
    # — nothing serves that, the font 404s, and a lane that measures text would be
    # measuring the FALLBACK while reporting success. e2e/boot.rb copies the real
    # app/assets/fonts bytes to the path on the right.
    ENGINE_FONTS = %w[
      studio/montserrat-latin.woff2
      studio/montserrat-latin-ext.woff2
    ].freeze

    def asset_path(source, **options)
      return "/e2e/fonts/#{source}" if ENGINE_FONTS.include?(source.to_s)

      super
    end

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

    # The host's importmap delivers NOTHING the lane needs, and that is the honest
    # stand-in. It used to serve Alpine from node_modules — necessary while the
    # engine's head fetched Alpine from a CDN this lane will not call. Now the engine
    # vendors Alpine and the head's own javascript_include_tag above delivers it, so
    # serving a second copy here would only mask whether that delivery works.
    def javascript_importmap_tags(*) = "".html_safe
  end

  helper AssetDelivery

  layout "e2e_lab"

  helper_method :logged_in?, :root_path, :current_user,
                :geo_country, :geo_state, :geo_blocked?, :geo_override_active?

  def logged_in? = false

  def root_path = "/"

  # The geo page and the badge read these off the controller in every host. Here
  # they are the lab visitor's fixed location — see #geo_settings.
  def geo_country = LAB_COUNTRY

  def geo_state = LAB_SUBDIVISION

  # False on purpose: the interesting states are the ones a CLICK produces, and a
  # page that arrived already blocked could not show the transition into it.
  def geo_blocked? = false

  def geo_override_active? = false

  # THE PROFILE REGISTRY ASKS THE VIEW FOR THIS. Studio::ProfileSections#resolve
  # reads `view.current_user` to run each row's `requires:` gate, and a nil user
  # is served NOTHING — so without this the newsletter row is silently dropped and
  # its specs pass over a page that never rendered it. Nil on every other lab
  # page, which render with logged_in? false and never reach it.
  def current_user = @user

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

  # The hold-to-confirm button, both levels.
  #
  # Renders studio/_hold_button by name. The button's browser half is an inline
  # script in that partial and its look is computed style from engine-motion.css
  # — neither is observable from the response bytes, which are identical whether
  # the script runs or not.
  def hold_button = render(:hold_button)

  # The birthday / age-gate handoff. No locals to prepare: the lab page sets up
  # the two cards' locals itself and both run in demo mode, because the dummy has
  # no /age/verify and inventing one would put the spec on a fiction.
  def birthday_gate = render(:birthday_gate)

  # The GLOBAL modal host (`$store.modals`), which no other lab page mounts —
  # /lab/birthday_gate drives the SCOPED host instead. Two separate partials with
  # two separate copies of the focus trap; this page is what lets a browser grade
  # the global one.
  def modal_host = render(:modal_host)

  # The geo manager, rendered as a host renders it: the engine's own template plus
  # the badge a host puts in its navbar.
  #
  # Everything the page decides is under test here — the squares paint from their
  # checkboxes, the summary chips rebuild from the editor, the tabs swap panels,
  # and the inline preview repaints the badge for THIS visitor's region. None of
  # that is observable in the response bytes: the markup is identical whether the
  # script runs, whether the CSS resolves, or whether a click is heard at all.
  #
  # The four geo helpers are fixtures, not stubs of the thing under test: they say
  # where this lab visitor is standing (US-CO), which is exactly what a host's
  # Studio::GeoDetection would have resolved. Resolving it for real would put a
  # network geocoder lookup inside a browser lane.
  def geo_settings
    @geo_setting = Studio::GeoSetting.new(
      app_name: Studio.app_name,
      enabled: true,
      banned_subdivisions: %w[US-WA US-ID],
      banned_countries: %w[CU]
    )
    @tab = params[:tab] == "countries" ? "countries" : "states"
    @simulated_region = "US-WA"
    render(:geo_settings)
  end

  # DEFECT 3's page — the @-time localiser script.
  #
  # Renders studio/_at_time_script plus stamps for it to localise. The script is the
  # subject; the stamps are what prove it ran.
  def at_time = render(:at_time)

  def phantom_deeplink = render(:phantom_deeplink)

  # The email manager's two preview frames — the ARTWORK box and the IN THE EMAIL
  # box — rendered side by side exactly as /admin/emails/:key renders them.
  #
  # A lab page rather than the real admin page because that one needs an admin
  # session and a settings table, and neither is what is under test here. What IS
  # under test is a size relationship between two boxes, which no markup
  # assertion can see: measured side by side they were 467x156 and 467x202, and
  # every string assertion about them passed.
  def email_banner_frames
    @banner = Studio::Banner.new(
      background_url: "/e2e/img/banner.gif",
      header: "Welcome Alex!",
      subtext: "your sign-in link is below",
      logo_url: "/e2e/img/logo.png",
      logo_alt: "Studio",
      scrim: 0.4
    )
    render(:email_banner_frames)
  end

  # The banner editor: the copy form beside the rendered banner it repaints.
  #
  # A lab page because the real /admin/emails/:key needs an admin session and a
  # settings table, and neither is what is under test. What IS under test is that
  # typing changes the picture and that Save reports whether there is anything to
  # save — both of which exist only after a browser has run the component.
  def email_banner_editor
    @banner = Studio::Banner.new(
      background_url: "/e2e/img/banner.gif", header: "Welcome Alex!",
      subtext: "your sign-in link is below", logo_url: "/e2e/img/logo.png",
      logo_alt: "Studio", scrim: 0.4
    )
    render(:email_banner_editor)
  end

  # THE PROFILE PAGE — the scroll-morph header and the dirty-check save bar.
  #
  # A PORO rather than a record, on purpose. The dummy runs sqlite :memory: (see
  # e2e/boot.rb) and the partials under test read the user through duck-typed
  # accessors — display_name, email, avatar_initials, avatar_color, first_name —
  # which is precisely the interface Studio::UserProfile gives a host model. There
  # is no row for a spec to seed and nothing here that a database would make more
  # true.
  #
  # `avatar` is deliberately ABSENT: the header's attachable guard drops the
  # upload affordance for a model with no attachment, which is both the cheaper
  # page and the shape three of the five consumers are in.
  class LabUser
    def display_name = "Pat Studio"
    def first_name = "Pat"
    def last_name = "Studio"
    def email = "pat@example.com"
    def avatar_initials = "PS"
    def avatar_color = "#6366f1"

    # The newsletter pair. Present as METHODS so the row's `requires:` gate is
    # satisfied, nil as VALUES, which is the "never asked" state the card opens
    # from. A LabUser without them would drop the row entirely, and every
    # newsletter spec would pass by never running.
    def joined_email_list_at = nil
    def left_email_list_at = nil

    # The birth trio: present as methods, empty as values — an account that has
    # the columns and has not filled them in, which is the state the calendar
    # opens from.
    def birth_day = nil
    def birth_month = nil
    def birth_year = nil
  end

  # Already on the list — the other half of the newsletter card, and the only
  # state whose control opens the confirmation.
  class LabSubscriber < LabUser
    def joined_email_list_at = Time.at(1_700_000_000)
  end

  # THE EDIT PAGE'S user needs one thing more: an `avatar` that answers
  # `attached?`. The identity header's `attachable` guard drops the upload
  # affordance entirely for a model without it, so the read page's LabUser (which
  # deliberately has none) would render no avatar trigger and the overlay specs
  # would pass over a page that has nothing to hover.
  class LabUserWithAvatar < LabUser
    def avatar = @avatar ||= Class.new { def attached? = false }.new
  end

  # AN ACCOUNT THAT ALREADY HAS A BIRTHDAY, which LabUser deliberately does not —
  # and the difference is not cosmetic. The only way to lose a stored birthday is
  # to have one, so every spec about NOT losing it needs this user; against
  # LabUser they would pass by having nothing to destroy.
  #
  # THE 31st IS THE WHOLE POINT. January has one and February does not, so
  # switching the month blanks the day and drops the field into the incomplete
  # state — which is exactly how a saved birthday used to get wiped by an edit
  # the person never finished. Any other day makes the spec inert.
  class LabUserWithBirthday < LabUserWithAvatar
    def birth_year = 1991
    def birth_month = 1
    def birth_day = 31
  end

  def profile
    @user = params[:subscribed].present? ? LabSubscriber.new : LabUser.new

    # RESOLVED, not hard-coded, because the resolution is part of what is under
    # test: the modal host must mount because a ROW DECLARED modals, not because
    # this page decided to render one. Hard-coding the host here would make the
    # spec green on a registry that had stopped asking for it.
    @profile_sections = Studio.profile_sections_for(view_context, page: :show)
    render(:profile)
  end

  # The EDIT page's two browser-only controls: the avatar's hover-to-change
  # overlay, and the birthday calendar. Separate from #profile because the read
  # and edit headers are deliberately different components — the read card is a
  # link with a decorative badge, the edit card is not a link and its avatar is a
  # button — and one page cannot exhibit both.
  # AN ACCOUNT WITH A LONG NAME AND A LONG ADDRESS, because the default fixture
  # is what hid this bug through two review rounds. "Pat Studio" /
  # "pat@example.com" is short enough to measure EXACTLY 0px of overlap against
  # the save controls at every width, so every geometry spec passed while an
  # ordinary long name lost 51px of itself to the Discard button.
  #
  # NEITHER VALUE IS EXTREME, deliberately. 33 characters is a double-barrelled
  # name; 64 is a corporate address with a first name, a surname and a real
  # domain. A fixture that had to be absurd to reproduce the defect would be
  # arguing the defect is not worth fixing.
  class LabUserWithLongIdentity < LabUserWithAvatar
    def display_name = "Bartholomew Fitzgerald-Wellington"
    def email = "bartholomew.fitzgerald-wellington@northwind-trading.example.com"
    def avatar_initials = "BF"
  end

  def profile_edit
    @user =
      if params[:identity] == "long"
        LabUserWithLongIdentity.new
      elsif params[:birthday].present?
        LabUserWithBirthday.new
      else
        LabUserWithAvatar.new
      end
    render(:profile_edit)
  end

  # Liveness. Playwright's webServer polls this before the first spec, so it must
  # not depend on anything a lab page needs.
  def up = render(plain: "ok")
end
