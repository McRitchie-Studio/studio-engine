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

    # Leaflet is addressed by LOGICAL path too (studio/site_footer/_map puts both
    # URLs on the map element), and e2e/boot.rb copies the engine's real files here.
    ENGINE_ASSET_PATHS = {
      "studio/leaflet.js" => "/e2e/js/studio/leaflet.js",
      "studio/leaflet.css" => "/e2e/css/studio/leaflet.css"
    }.freeze

    def asset_path(source, **options)
      return "/e2e/fonts/#{source}" if ENGINE_FONTS.include?(source.to_s)
      # The engine's pinned ES modules, which e2e/boot.rb copies to /e2e/modules.
      return "/e2e/modules/#{source}" if Studio::Engine.javascript_module_logical_paths.include?(source.to_s)
      return ENGINE_ASSET_PATHS[source.to_s] if ENGINE_ASSET_PATHS.key?(source.to_s)

      super
    end

    # importmap-rails resolves each pin through path_to_asset, which Rails defines
    # as an alias bound to the ORIGINAL asset_path, so the override above would not
    # reach it.
    def path_to_asset(source, options = {}) = asset_path(source, **options)

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

    # What a host's javascript_importmap_tags renders, less the entry point: the
    # import map (the engine's pins alone, since the dummy has no
    # config/importmap.rb) and the modulepreload links for what it preloads. The
    # dummy has no application.js to import, so there is no `import "application"`;
    # the head's own javascript_import_module_tag then boots studio/application
    # through this map, the path every consumer takes.
    #
    # It once served Alpine from node_modules, while the engine's head fetched
    # Alpine from a CDN this lane will not call. The engine vendors Alpine now and
    # the head's javascript_include_tag delivers it, so a second copy here would
    # only mask whether that delivery works.
    def javascript_importmap_tags(*)
      safe_join([javascript_inline_importmap_tag, javascript_importmap_module_preload_tags], "\n")
    end
  end

  helper AssetDelivery

  layout "e2e_lab"

  helper_method :logged_in?, :root_path, :current_user, :admin?,
                :geo_country, :geo_state, :geo_blocked?, :geo_override_active?

  # EVERY ACTION DECLARES ITS OWN SIDEBAR, and it is declared as a local of the
  # REQUEST rather than written into the engine's process-wide config.
  #
  # WHAT WENT WRONG WHEN IT WAS NOT. `Studio.sidebar_sections` is a
  # `mattr_accessor` — ONE slot for the whole process — and #bar_stack used to
  # assign it from `?sidebar=1` on the way past. So one visit to
  # /lab/bar_stack?sidebar=1 armed the link sidebar for every request that
  # followed, whatever that page declared. Measured on this lane at a73edfe:
  # /lab/toast_over_banner served 2 trigger buttons, 2 slide-out panels and
  # --nav-h 145px after that visit, against 0/0/125px before it.
  #
  # The browser lane never went red for it, which is the part worth remembering:
  # Playwright walks e2e/ in FILE-NAME order, and nav_collapse.spec.js — which
  # visits /lab/bar_stack with no `sidebar` param, clearing the slot — happens to
  # sort between the contaminator and the victim. The lane was clean by
  # alphabet. Run the two adjacent and every assertion still passes, so its own
  # green check could not have reported this.
  #
  # THE DECLARATION IS A CALLABLE, registered once in test/dummy/config/
  # application.rb, which is the form docs/NEW_APP_SETUP.md shows consumers
  # using for dynamic sections. It resolves through the real
  # Studio::SidebarSections.resolve on every render, so the lab still exercises
  # the engine's actual host seam — it just reads this request instead of the
  # last one's leftovers. Nothing here writes a process global, so the lab pages
  # are genuinely order-independent and thread-independent, which is what
  # playwright.config.js's `workers` note and
  # test/integration/e2e_lab_isolation_test.rb now stand on.
  before_action :declare_lab_sidebar_sections

  # Read by the declared callable through `view.controller`. Public because
  # `respond_to?` is how that callable tells a lab request from any other
  # controller's; it is not an action — test/dummy/config/routes.rb draws the
  # lab's routes one by one, so nothing reaches a controller method that has no
  # route.
  attr_reader :lab_sidebar_sections

  # Signed in ONLY where a page asked for it (#bar_stack sets @lab_signed_in).
  # Every other lab action leaves it nil, so they render the signed-out navbar
  # exactly as before — the profile pages set @user for the profile registry and
  # must NOT become "logged in" as a side effect of that.
  def logged_in? = @lab_signed_in.present?

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
  # THE SIGNED-IN HEADER'S OWN FIXTURE, and the reason it is not LabUser.
  #
  # A header's width defect is a defect of the WIDEST ordinary content, and every
  # signed-out or short-named fixture measures 0px of overflow at every width —
  # the same trap test/dummy's LabUserWithLongIdentity was written for one page
  # down. This user carries what a real signed-in visitor carries: a two-word
  # display name, a level, and a connected wallet, which is what fills the
  # right-hand column's second row.
  #
  # NEITHER VALUE IS EXTREME. "Alexandra Mcritchie" is 19 characters — a first
  # name and a surname — and the wallet string is the engine's own truncated
  # form, not a full base58 address.
  class LabHeaderUser
    def display_name = "Alexandra Mcritchie"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#6366f1"
    def avatar_initials = "AM"
    def level = 7
    def solana_connected? = true
    def truncated_solana = "7xKX…gAsU"
  end

  # ADMIN, because an admin viewer is the one who gets the extra cog in the icon
  # rail — and an admin is exactly who is looking at a development banner.
  def admin? = @lab_admin.present?

  def bar_stack
    # `signed_in` renders the right-hand user column — the half of this header a
    # signed-out page cannot show at all. `devnet` adds the DEVNET chip to the
    # environment bar, and `admin` the cog. `balance` is the one local that
    # swaps the right column from `user-nav-fit` (max-width) to `user-nav-col`
    # (a hard width), which is the widest shape the partial has.
    if params[:signed_in].present?
      @lab_signed_in = true
      @user = LabHeaderUser.new
    end
    @lab_devnet = params[:devnet].present?
    @lab_admin = params[:admin].present?
    @lab_balance = params[:balance].present?
    render(:bar_stack)
  end

  # What a consuming app declares in config/initializers/studio.rb.
  # mcritchie-industries — one of the two apps that render THIS partial rather
  # than a fork of it — declares sections, so the trigger is part of the header
  # under test rather than an optional extra.
  LAB_SIDEBAR_SECTIONS = [
    { title: "Site", links: [{ label: "Home", href: "/", emoji: "🏠" }] }
  ].freeze

  # `?sidebar=1` on ANY lab page, answered for that request alone. The header
  # specs drive it on /lab/bar_stack; nothing stops another page asking, and
  # nothing carries the answer past this request.
  def declare_lab_sidebar_sections
    @lab_sidebar_sections = params[:sidebar].present? ? LAB_SIDEBAR_SECTIONS : []
  end
  # PRIVATE by name rather than by a trailing `private` section: every public
  # instance method on a controller is an action_method, and this file's public
  # surface is deliberately the lab's routed actions plus the helpers it declares
  # above. A trailing `private` here would swallow #up, which routes.rb draws.
  private :declare_lab_sidebar_sections

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

  # THE TOAST / BANNER COLLISION — three engine partials that only misbehave
  # together.
  #
  # studio/banners/stack, layouts/studio/flash and studio/modals/host each work
  # perfectly alone, and every existing tier proved exactly that. The defect
  # lives in the seam: opening a modal puts `modal-open` on body, which lifts the
  # bar stack to a pinned var(--z-banner) at top 0 — over the same pixels
  # #toast-container's fixed top-0 padding puts the toast's Dismiss button on.
  # Neither the markup nor the token values show it; only a hit test does.
  #
  # No locals to prepare. The environment banner renders because
  # Studio.show_environment_banner? is true outside production, the toast is
  # raised by an event the page dispatches, and the modal is opened through the
  # engine's own store — so the page under test is assembled entirely out of
  # engine behaviour, exactly as a consumer's layout assembles it.
  def toast_over_banner = render(:toast_over_banner)

  # The toast root as a layout renders it, with the request's flash in it, under
  # Turbo: ?notice= and ?alert= set the flash, so a spec can visit one page from
  # another and come Back.
  def toast_flash
    flash.now[:notice] = params[:notice] if params[:notice].present?
    flash.now[:alert] = params[:alert] if params[:alert].present?
    render(:toast_flash, layout: "survey_turbo_lab")
  end

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

  # The engine's importmap pins, in a browser. The page renders the host's real
  # import map (javascript_inline_importmap_tag, the map the dummy drew from the
  # engine's config/importmap.rb with no host edit) and no entry point; the spec
  # imports "studio/<name>" through it.
  def engine_modules = render(:engine_modules)

  # The site identity manager (/admin/link_preview), rendered from the engine's
  # own template with the instance variables its controller sets. A lab page
  # rather than the real one because that needs an admin session and Active
  # Storage tables, and neither is what the spec drives: the live card, the
  # crop modal's wiring, and the layout at phone width.
  def site_identity
    @installed = true
    @setting = Studio::SiteIdentity.new(
      app_name: Studio.app_name, title: "Saved title",
      description: "Saved description of what this app is."
    )
    @uploads_available = true
    @default_image_url = "/e2e/img/banner.gif"
    @static_image_url = nil
    @domain = "lab.example"
    render(:site_identity)
  end


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
  # which is the interface every host User defines for itself. There is no row for
  # a spec to seed and nothing here that a database would make more true.
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

  # THE STYLE GUIDE'S MODALS SECTION — the page-scoped host plus the two
  # simulator sections whose controls are GENERATED rather than rendered.
  #
  # No locals to prepare: style/_modals resolves its own web3 / leveling gates and
  # takes no arguments, which is exactly how style/index renders it. The browser
  # programs under test — the registry-driven control build and the dsModals stack
  # demos — are inline scripts in that engine partial, so the response bytes are
  # identical whether either one runs.
  def style_modals = render(:style_modals)

  # HOST-SUPPLIED LOCALS THAT LAND INSIDE A JS STRING LITERAL, across the blocks
  # that take one — success/error card event names and the tx link's cluster query.
  #
  # No locals to prepare here either: the hostile values ARE the locals, and the lab
  # rule says the page sets those up. The partials render standalone because none of
  # these paths reaches a store — a $dispatch goes to the window, and the tx link
  # only resolves an href.
  def js_attribute_locals = render(:js_attribute_locals)

  # THE FIRST-NAME STEP'S EMPTY-FIELD ERROR, in three modes.
  #
  # No locals to prepare here: the modes ARE the locals, and the lab rule says the
  # page sets those up. This action exists only to render the view.
  def onboarding_first_name = render(:onboarding_first_name)

  # The session-drift page (e2e/session_drift.spec.js).
  #
  # The browser program under test is studio/_session_stamp, which the ENGINE head in
  # this lab's layout renders by name: the meta stamp plus studio/session.js. A host
  # gets the stamp's INPUT from Studio::SessionDrift; the lab supplies that one input
  # from the query string instead, which is the same relationship every other lab
  # page has to its partial's locals. Only this action sets it, so every other lab
  # page keeps a head with no stamp and no store.
  #
  # No rehydrateUrl: the lab has no session to rehydrate, so drift is final `stale`.
  #
  # NOT a helper_method. The stamp partial renders the store for any view that
  # responds to studio_session_page_stamp, and a helper_method would answer on
  # EVERY lab page — loading the store into twenty unrelated specs. So only this
  # action's view gains the method.
  module SessionStampInput
    def studio_session_page_stamp = controller.instance_variable_get(:@session_stamp)
  end

  def view_context
    super.tap { |view| view.extend(SessionStampInput) if @session_stamp }
  end

  def session_drift
    @session_stamp = {
      v: 1,
      state: params[:state] == "authenticated" ? "authenticated" : "anonymous",
      fingerprint: params[:fp].presence || "anonymous",
      issuedAt: params[:issued].to_i,
      expiresAt: nil,
      rehydrateUrl: nil,
      identities: {}
    }
    render(:session_drift)
  end

  # Liveness. Playwright's webServer polls this before the first spec, so it must
  # not depend on anything a lab page needs.
  # TWO SIDEBARS ON ONE PAGE — the link sidebar beside a host's own panel, both built
  # on the shared components/_sidebar_panel. The only page where the link sidebar's
  # click bridge can be caught claiming a close button it did not render.
  def sidebar_panels = render(:sidebar_panels)

  # ---- The site footer and the booking primitives (docs/SITE_FOOTER.md) ------
  #
  # The facts a host would declare in config.site_footer. test/dummy's
  # application.rb points Studio.site_footer at `lab_site_footer`, so only these
  # pages have a footer: every other lab page answers nil and renders none.
  #
  # It exercises each rule a row can carry: a booking link, a disabled label (nil
  # href), an off-site link, an unlinked social profile (nil url) and one with no
  # mark of its own.
  LAB_SITE_FOOTER = {
    name: "Lab Studio",
    tagline: "Everything, by example",
    email: "team@lab.example",
    address: { street: "123 Example St", city_line: "Washington, DC 20024", lat: 38.8894, lng: -77.0352 },
    social: [
      ["LinkedIn", :linkedin, "https://www.linkedin.com/in/lab/"],
      ["Instagram", :instagram, nil],
      ["Mastodon", :mastodon, "https://social.lab.example/@lab"]
    ],
    columns: [
      ["Contact", [["Schedule a call", "/lab/site_footer/schedule", { booking: true }],
                   ["Contact", "/lab/site_footer"]]],
      ["Company", [["Home", "/lab/site_footer"], ["Career", nil], ["Blog", "https://blog.lab.example"]]]
    ],
    legal: [["Privacy Policy", "/lab/site_footer"], ["Terms of Service", "/lab/site_footer/terms"]]
  }.freeze

  SITE_FOOTER_VARIANTS = %w[index terms home schedule plain crops columns].freeze

  # Link columns for /lab/site_footer/columns/:n, the first n of these. They are
  # shaped like a real site's: a Contact column holding an email address (with a
  # hyphen in it, where a browser would wrap), then short columns. Two of them
  # is a small site's footer; four is a full one. A fifth is past what one row
  # holds. The names are made up.
  LAB_COLUMN_POOL = [
    ["Contact", [["team@lab-studio.example", "mailto:team@lab-studio.example"],
                 ["Schedule a call", "/lab/site_footer/schedule"], ["Contact", "/lab/site_footer"]]],
    ["Company", [["Home", "/lab/site_footer"], ["About", "/lab/site_footer"], ["Career", nil]]],
    ["Solutions", [["Packages", "/lab/site_footer"], ["Build an app", "/lab/site_footer"]]],
    ["Legal", [["Privacy Policy", "/lab/site_footer"], ["Terms of Service", "/lab/site_footer/terms"]]],
    ["Resources", [["Documentation", "/lab/site_footer"], ["Status", "/lab/site_footer"]]]
  ].freeze

  attr_reader :lab_site_footer

  # One action, seven pages. `plain` is the footer with no address: no Location
  # band, no map and no Leaflet request. `crops` is three booking frames, two
  # cropped to different windows and one whole. `columns` is the footer with two
  # to five link columns. The layout is the lab's plus Turbo,
  # because the map's remount on a Turbo visit is one of the things under test.
  def site_footer
    variant = SITE_FOOTER_VARIANTS.include?(params[:variant]) ? params[:variant] : "index"
    @lab_site_footer = variant == "plain" ? LAB_SITE_FOOTER.except(:address) : LAB_SITE_FOOTER
    if variant == "columns"
      columns = LAB_COLUMN_POOL.first(params[:n].to_i.clamp(2, 5))
      # ?hint=1.5 gives the first column a width hint, the way a host writes one.
      columns = [columns.first + [{ width: params[:hint].to_f }]] + columns.drop(1) if params[:hint].present?
      @lab_site_footer = LAB_SITE_FOOTER.merge(columns: columns)
    end
    render("site_footer_#{variant}", layout: "site_footer_lab")
  end

  def up = render(plain: "ok")
end
