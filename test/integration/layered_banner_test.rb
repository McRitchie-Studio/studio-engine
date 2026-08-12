# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] The LAYERED email banner — background image with the header,
# sub-text and logo as live HTML on top.
#
# Two properties carry this feature, and neither is "it renders":
#
#   1. It reaches OUTLOOK. Outlook on Windows renders through Word, which
#      ignores background-image on nearly everything. Without the VML block the
#      banner is a blank cell there — and Outlook is exactly the client that
#      cannot be checked by looking at Gmail.
#   2. It does not disturb what already ships. Every mailer in every app sets
#      @banner_url and renders an <img>. Layered is opt-in; a mailer that knows
#      nothing about it must render byte-for-byte as before.
class LayeredBannerTest < ActiveSupport::TestCase
  # The dummy app has no schema; the engine's other DB-touching guard builds its
  # table the same way. Runs the REAL migration so a mistake in it fails here
  # rather than in a host's db:migrate.
  def self.ensure_settings_table!
    return if ActiveRecord::Base.connection.table_exists?(:studio_email_settings)

    require_relative "../../db/migrate/20260812000000_create_studio_email_settings"
    CreateStudioEmailSettings.new.migrate(:up)
  end

  def setup
    self.class.ensure_settings_table!
    Studio::EmailSetting.delete_all
  end

  def teardown
    Studio::EmailSetting.delete_all
    Studio::EmailCatalog.reset!
  end

  # Hand-rolled: Minitest 6 dropped minitest/mock, so there is no .stub.
  def stub_singleton(mod, name, value)
    original = mod.method(name)
    mod.define_singleton_method(name) { |*| value }
    yield
  ensure
    mod.define_singleton_method(name, original)
  end

  def view
    v = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    v.singleton_class.include(Rails.application.routes.url_helpers)
    v
  end

  def banner(**overrides)
    Studio::Banner.new(**{
      background_url: "https://cdn.example.com/bg.gif",
      header: "Welcome Mason!",
      subtext: "your sign-in link is below",
      logo_url: "https://cdn.example.com/logo.png",
      logo_alt: "Studio"
    }.merge(overrides))
  end

  def render_banner(**overrides)
    view.render(partial: "studio/mailers/layered_banner", locals: { banner: banner(**overrides) })
  end

  # --- 1. it has to reach Outlook -------------------------------------------

  test "the background is carried three ways, one of them VML for Outlook" do
    html = render_banner

    assert_includes html, %(background="https://cdn.example.com/bg.gif"),
      "the td background ATTRIBUTE is what the widest set of clients honour"
    # Unquoted url() on purpose: ERB entity-escapes an apostrophe inside an
    # attribute, and while a parser decodes it, email sanitisers are crude.
    assert_includes html, "background-image:url(https://cdn.example.com/bg.gif)",
      "CSS for the clients that prefer it"
    refute_includes html, "&#39;", "no entity-escaped quotes in the style attribute"

    assert_includes html, "<!--[if gte mso 9]>",
      "without a conditional the VML would reach clients that cannot parse it"
    assert_includes html, "v:rect", "Outlook renders through Word and ignores background-image"
    assert_includes html, "v:fill", "the fill is what actually paints the picture in Outlook"
    assert_includes html, "</v:rect>", "an unclosed VML rect swallows the rest of the email"
  end

  test "a blocked or slow image still leaves legible text" do
    html = render_banner

    assert_match(/bgcolor="#[0-9A-Fa-f]{6}"/, html,
      "the cell needs a brand floor, or white text lands on white while the image loads")
  end

  # --- 2. it must not disturb what already ships -----------------------------

  test "a mailer that only sets @banner_url still renders the plain img" do
    layout = File.read(File.expand_path("../../app/views/layouts/branded_mailer.html.erb", __dir__))

    assert_includes layout, "elsif @banner_url.present?",
      "the img path must remain, and remain the fallback"
    assert_includes layout, %(<img src="<%= @banner_url %>"),
      "every shipped mailer sets @banner_url — that path cannot change shape"
    assert_includes layout, "@banner.respond_to?(:renderable?)",
      "layered is opt-in: an app that sets no @banner must be unaffected"
  end

  test "an empty banner never displaces the img path" do
    refute Studio::Banner.new.renderable?,
      "a banner with no artwork and no header would render an empty cell over the real one"
    refute Studio::Banner.new(header: "").renderable?
    assert Studio::Banner.new(header: "Welcome Mason!").renderable?
    assert Studio::Banner.new(background_url: "https://x/y.gif").renderable?
  end

  # REGRESSION GUARD, and the reason for two.
  #
  # A table cell's padding ADDS to its declared height. Carrying height:300 AND
  # 26px of vertical padding on the tinted cell rendered a 350px banner — which
  # is what Mr. McRitchie saw in his inbox. Dropping the height instead made it
  # 300 but shrank the scrim to a band across the middle, because a tinted cell
  # with no height only covers its own content. Full height plus
  # horizontal-ONLY padding is the shape that satisfies both.
  test "the tinted cell carries the full height and no vertical padding" do
    html = render_banner

    assert_match(/padding:0 \d+px/, html,
      "vertical padding on a sized cell ADDS to its height — 300 rendered as 352"
    )
    refute_match(/padding:[1-9]\d*px \d+px/, html,
      "any non-zero vertical padding reintroduces the over-tall banner")
    # The cell that PAINTS the wash must itself be full height, or the tint
    # covers only its content and leaves unwashed bands top and bottom.
    tinted = Nokogiri::HTML(html).css("td").find { |td| td["style"].to_s.include?("background-color:rgba") }
    refute_nil tinted, "no tinted cell found"
    assert_includes tinted["style"], "height:#{Studio::Banner::DEFAULT_HEIGHT}px",
      "the tinted cell must be full height or the scrim becomes a band across the middle"
  end

  # The banner fills its box rather than floating in the middle of it, and it
  # keeps doing so when the greeting wraps.
  #
  # A gap tuned to fill 300px for "Welcome Alex!" leaves a two-line header
  # clipped at the top with its logo jammed on the bottom edge, because the
  # block grows by a whole line while the box does not. Measured in a browser:
  # 31px at both edges on one line, 45px on two, no clipping either way.
  test "the gap tightens when the greeting wraps to a second line" do
    one_line = render_banner(header: "Welcome Alex!")
    two_line = render_banner(header: "Welcome Bartholomew Fitzgerald-Montgomery!")

    # Keyed on the sub-text's colour, not its font size: the sizes are
    # proportional now, so pinning a literal px value would break on any
    # height change and tell us nothing about the gap.
    one_gap = one_line[/margin:0 0 (\d+)px;[^"]*color:#efeaff/, 1].to_i
    two_gap = two_line[/margin:0 0 (\d+)px;[^"]*color:#efeaff/, 1].to_i

    assert two_gap.positive?, "expected a gap before the logo"
    assert two_gap < one_gap,
      "a wrapping header must get LESS space before the logo, or it clips at both edges"
  end

  # REGRESSION GUARD. Type was hardcoded at 42px, which looked right in a 300px
  # banner and OVERFLOWED a 200px one: the box shrank, the words did not, and it
  # rendered 238px tall with the header clipped at both edges. Everything is now
  # a proportion of the height, so a height change is a one-line edit.
  test "type scales with the banner rather than being hardcoded" do
    tall  = render_banner(height: 300)
    short = render_banner(height: 200)

    tall_size  = tall[/font-size:(\d+)px;line-height:\d+px;font-weight:700/, 1].to_i
    short_size = short[/font-size:(\d+)px;line-height:\d+px;font-weight:700/, 1].to_i

    assert short_size < tall_size,
      "a shorter banner needs smaller type, or the content overflows the box"
    assert_operator short_size, :>, 0
  end

  # --- the scrim -------------------------------------------------------------

  test "the scrim is applied by default because artwork does not guarantee contrast" do
    html = render_banner

    assert_match(/background-color:rgba\(24,16,64,0\.\d+\)/, html,
      "white text over a pale sky is unreadable without a wash")
  end

  test "the scrim can be turned off for artwork dark enough to carry type" do
    html = render_banner(scrim: 0)

    refute_includes html, "background-color:rgba(24,16,64,",
      "scrim: 0 must mean no overlay cell at all, not a zero-alpha one"
  end

  test "a nonsense scrim is clamped rather than emitted" do
    assert_equal 1.0, Studio::Banner.new(scrim: 4).scrim_opacity
    assert_equal 0.0, Studio::Banner.new(scrim: -2).scrim_opacity
    assert_equal Studio::Banner::DEFAULT_SCRIM, Studio::Banner.new.scrim_opacity
  end

  # --- the pieces the banner is built from -----------------------------------

  test "header, sub-text and logo all render on top of the picture" do
    doc = Nokogiri::HTML(render_banner)

    assert_includes doc.text, "Welcome Mason!"
    assert_includes doc.text, "your sign-in link is below"
    refute_empty doc.css('img[src="https://cdn.example.com/logo.png"]'),
      "the logo is a real img in flow — it is never composited into the artwork"
  end

  test "each piece is optional" do
    assert_includes render_banner(subtext: nil, logo_url: nil), "Welcome Mason!"
    refute_includes render_banner(logo_url: nil), "<img"
  end

  # --- the operator's tint ---------------------------------------------------
  #
  # The scrim is a judgement about a picture, and the picture changes without a
  # deploy — so an operator can set it on /admin/emails and that value outranks
  # the registry. These pin the ORDER, which is the part that silently goes
  # wrong: a saved 40% that loses to a registered default is invisible until
  # someone looks at an inbox.

  test "the default tint is 40%" do
    assert_in_delta 0.40, Studio::Banner::DEFAULT_SCRIM, 0.001
  end

  test "a saved tint outranks the registry" do
    Studio::EmailCatalog.register("magic_link", scrim: 0.9)
    Studio::EmailSetting.set_scrim("magic_link", 25)

    assert_in_delta 0.25, Studio::EmailCatalog.scrim("magic_link"), 0.001,
      "the operator is the one looking at the artwork"
  ensure
    Studio::EmailSetting.where(email_key: "magic_link").delete_all
    Studio::EmailCatalog.reset!
  end

  test "clearing the tint falls back to the registry, not to whatever was saved" do
    Studio::EmailCatalog.register("magic_link", scrim: 0.6)
    Studio::EmailSetting.set_scrim("magic_link", 25)
    Studio::EmailSetting.set_scrim("magic_link", nil)

    assert_in_delta 0.6, Studio::EmailCatalog.scrim("magic_link"), 0.001,
      "blank means 'use the default', not 'pin today's default'"
  ensure
    Studio::EmailSetting.where(email_key: "magic_link").delete_all
    Studio::EmailCatalog.reset!
  end

  test "the tint is stored as the percent the operator typed" do
    record = Studio::EmailSetting.set_scrim("magic_link", 40)

    assert_equal 40, record.scrim_percent,
      "storing the operator's own units keeps the round-trip lossless"
    assert_equal 40, Studio::EmailCatalog.scrim_percent("magic_link")
  ensure
    Studio::EmailSetting.where(email_key: "magic_link").delete_all
  end

  test "a missing settings table never stops an email" do
    stub_singleton(Studio::EmailSetting, :table_ready?, false) do
      assert_nil Studio::EmailSetting.scrim_for("magic_link")
      refute_nil Studio::EmailCatalog.scrim_percent("magic_link"),
        "an app that has not run the migration must still send email"
    end
  end

  # --- artwork resolution ----------------------------------------------------

  test "the standard magic link inherits the engine's layered artwork" do
    entry = Studio::EmailCatalog.entry("magic_link")

    assert_equal "emails/magic-link-background.gif", entry.background
    assert_equal "emails/logo-horizontal.png", entry.logo

    %w[emails/magic-link-background.gif emails/logo-horizontal.png].each do |asset|
      path = File.expand_path("../../app/assets/images/#{asset}", __dir__)
      assert File.file?(path), "#{asset} must ship in the gem"
    end
  end

  # The artwork ships RAW and is cropped by the client, not by us. Mr. McRitchie
  # chose the full-width 2:1 framing, which background-size:cover produces from
  # the 1200x720 original — so a destructive re-crop in the repo would throw away
  # detail we can never get back AND lock in a framing the design may revisit.
  test "the background ships at full size and is cropped at display time" do
    path = File.expand_path("../../app/assets/images/emails/magic-link-background.gif", __dir__)
    header = File.binread(path, 10)

    assert_equal "GIF89a", header[0, 6], "the background must stay an animated GIF"
    width, height = header[6, 4].unpack("v2")
    assert_equal 1200, width,  "the raw asset is 1200 wide — cropping belongs to the client"
    assert_equal 720,  height, "the raw asset is 720 tall — cover crops it to 2:1 at render"
  end

  test "the banner box is the 600px email card, and cover does the cropping" do
    assert_equal 600, Studio::Banner::DEFAULT_WIDTH,
      "600px is the width every email client and template assumes"
    assert_equal 200, Studio::Banner::DEFAULT_HEIGHT

    html = render_banner
    assert_includes html, "background-size:cover",
      "cover is what turns a 1200x720 asset into the chosen full-width 2:1 framing"
    assert_includes html, "background-position:center",
      "without centring, cover crops from a corner"
  end

  # A mail client fetches from an inbox, where a root-relative path resolves
  # against nothing.
  test "artwork resolves to an absolute url for the inbox" do
    previous = ActionMailer::Base.default_url_options
    ActionMailer::Base.default_url_options = { host: "mcritchie.studio" }

    url = Studio::EmailCatalog.background_url("magic_link")
    assert url.to_s.start_with?("https://mcritchie.studio/"),
      "a relative banner path loads nothing in an inbox (got #{url.inspect})"
  ensure
    ActionMailer::Base.default_url_options = previous
  end

  test "a host can override any piece per send" do
    Studio::EmailCatalog.register("magic_link", background: "emails/custom.gif", scrim: 0.1)

    entry = Studio::EmailCatalog.entry("magic_link")
    assert_equal "emails/custom.gif", entry.background
    assert_in_delta 0.1, entry.scrim, 0.001
    assert_equal "emails/logo-horizontal.png", entry.logo,
      "overriding the background must not drop the inherited logo"
  ensure
    Studio::EmailCatalog.reset!
  end
end
