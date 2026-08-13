# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"
require "digest"
require "uri"

# [integration] The SIGN-IN email carries no branding the engine owns.
#
# THE DEFECT THESE EXIST FOR, and why it was worth fixing before anyone was hurt.
#
# Studio::EmailCatalog::STANDARD seeded magic_link with
# logo: "emails/logo-horizontal.png" — the white McRITCHIE STUDIO wordmark — and
# register() merges on `logo.presence`, so an OMITTED key INHERITS. Any host that
# registered this email for an unrelated reason (a relabel, attaching a preview
# builder) inherited the engine's identity into its own sign-in email without
# ever naming it. McRitchie Studio itself registers magic_link to attach exactly
# one preview builder and names no logo, so it was inheriting the mark it owns.
#
# It was an UPGRADE TRAP, not a live leak, and that is the sharper shape. The
# three apps carrying no email initializer — moms-app, mcritchie-industries,
# acquisition-studio — pin 0.32.1 / 0.32.2 / 0.13.1, and app/services/studio/
# email_catalog.rb does not exist in the gem they run. They inherited nothing.
# The routine dependency bump that brought any of them forward would have put
# another brand's wordmark on their most-sent email, with no code change of their
# own and nobody looking for it. That is what this file stops.
#
# WHY THESE ASSERT RESOLUTION AND NOT SPELLING. A rendered src looks identical
# whether the host owns the file or the gem does, and that indistinguishability
# IS the bug: turf-monster named "emails/logo-horizontal.png", shipped no such
# file, and Sprockets quietly served the engine's copy. A test reading the src
# string would have called that correct. So each <img> is taken back to a FILE on
# the engine's own asset load path — the same directories a consumer's pipeline
# searches, because a Rails engine contributes them.
#
# WHY THE ALT TEXT IS NOT EVIDENCE. Studio::Banner sets logo_alt from
# Studio.app_name, so it always agrees with the HOST and never with the pixels.
# turf's read alt="Turf Monster" over the Studio wordmark for weeks, and nobody
# reviewing that email could have seen it.
class MagicLinkLogoTest < ActiveSupport::TestCase
  # A literal token, not a minted Studio::Link: the mailer only turns the token
  # into a URL (magic_link_url_for is pure routing) and the dummy app carries no
  # schema, so minting a row would couple this to the links table for nothing.
  TOKEN = "tokenfortest1234"
  RECIPIENT = "reader@example.test"

  def setup
    @previous_url_options = ActionMailer::Base.default_url_options
    ActionMailer::Base.default_url_options = { host: "example.test" }
    Studio::EmailCatalog.reset!
  end

  def teardown
    ActionMailer::Base.default_url_options = @previous_url_options
    Studio::EmailCatalog.reset!
  end

  def html
    message = UserMailer.magic_link(RECIPIENT, TOKEN)
    (message.html_part&.body || message.body).to_s
  end

  def doc = Nokogiri::HTML(html)

  ENGINE_ASSET_DIRS = Studio::Engine.paths["app/assets"].existent.freeze

  # The file the engine would serve for a rendered URL, or nil when the engine
  # ships nothing by that name.
  #
  # `.existent` expands to the four LEAF asset directories (images, javascripts,
  # stylesheets, tailwind), which is what makes this reverse map exact rather
  # than a prefix guess.
  def engine_file_behind(url)
    logical = URI.parse(url.to_s).path.to_s.delete_prefix("/")
    return nil if logical.empty?

    ENGINE_ASSET_DIRS.map { |dir| File.join(dir, logical) }.find { |path| File.file?(path) }
  end

  # An asset this gem ships, ASSERTED to exist rather than assumed.
  #
  # Silence is the failure mode all through this path:
  # Studio::EmailCatalog#asset_path rescues StandardError to nil,
  # absolute_asset_url does the same, and _layered_banner.html.erb gates every
  # background path on `background_url.present?`. An upstream rename therefore
  # raises NOTHING and the email quietly ships a flat colour box. A guard built
  # on "we found no wordmark" would go quiet right along with it.
  def engine_asset(logical)
    path = File.join(Studio::Engine.root, "app/assets/images", logical)
    assert File.file?(path), "#{logical} must ship in the gem, or the guards below prove nothing"
    path
  end

  def wordmark_digest = Digest::SHA256.file(engine_asset("emails/logo-horizontal.png")).hexdigest

  # --- the positive control -------------------------------------------------

  # EVERY absence asserted below is vacuous without this. An email whose banner
  # failed to render carries no wordmark either, and would pass the lot of them.
  test "the sign-in banner still draws its own artwork from the gem" do
    cell = doc.css("td[background]").first

    refute_nil cell,
      "the layered banner did not render — every absence guard below would pass on an empty email"
    assert_equal engine_asset("emails/magic-link-background.gif"),
                 engine_file_behind(cell["background"]),
                 "the background must resolve to the sign-in email's own artwork, not another email's"
  end

  # --- the guard ------------------------------------------------------------

  # THE PROPERTY: these pixels never reach a host's inbox. Compared by BYTES, so
  # renaming the wordmark and seeding the new name is caught too — the guard is
  # about the mark, not about a string somebody can edit.
  test "the sign-in email carries no wordmark the engine owns" do
    document = doc
    refute_nil document.css("td[background]").first,
      "the banner did not render, so finding no wordmark proves nothing"

    document.css("img").each do |img|
      file = engine_file_behind(img["src"])
      next if file.nil?

      refute_equal wordmark_digest, Digest::SHA256.file(file).hexdigest,
        "the McRitchie Studio wordmark is in this email " \
        "(alt=#{img["alt"].inspect}, which names the HOST and proves nothing)"
    end
  end

  # The seed itself, at the merge — which is where the surprise lives. ARTWORK
  # riding the gem is the point of the seed and stays; a WORDMARK is somebody's
  # identity, and that is where the line is drawn.
  test "the sign-in seed lends artwork but no mark" do
    entry = Studio::EmailCatalog.entry("magic_link")

    assert_nil entry.logo,
      "the engine's wordmark must not ride the seed into a host's sign-in email"
    assert_nil Studio::EmailCatalog.resolved_logo_url("magic_link")
    assert_equal "emails/magic-link-background.gif", entry.background,
      "ARTWORK still rides the gem — the line is at branding, not at engine assets"
  end

  # --- acceptance, in the exact shape the hub uses --------------------------

  # This is McRitchie Studio's real registration, reduced to its shape: it
  # attaches one preview builder and names no logo. Before the fix, that call
  # inherited the wordmark, and a host wanting rid of it had to pass logo: ""
  # — a line the next maintainer would tidy away as redundant.
  test "a host registering this email to attach a preview inherits no mark" do
    Studio::EmailCatalog.register("magic_link", preview: -> { :whatever })

    assert_nil Studio::EmailCatalog.entry("magic_link").logo,
      "omitting logo: inherits the seed, so the seed must carry no mark"
    assert_nil Studio::EmailCatalog.resolved_logo_url("magic_link")

    document = doc
    refute_nil document.css("td[background]").first, "the host's banner did not render"
    assert_empty document.css("img").filter_map { |img| engine_file_behind(img["src"]) },
      "a host that named no logo is sending an image the engine owns"
  end

  # THE OTHER HALF, or the guard above would also pass on an engine that had
  # simply lost the ability to draw a logo at all — and then a host opting in
  # would get silence instead of its mark.
  test "a host that names its own mark still gets one" do
    Studio::EmailCatalog.register("magic_link", logo: "emails/our-own-mark.png")

    sources = doc.css("img").map { |img| img["src"].to_s }

    assert sources.any? { |src| src.end_with?("/emails/our-own-mark.png") },
      "an app that asked for its own logo must get it: #{sources.inspect}"
    assert_empty sources.filter_map { |src| engine_file_behind(src) },
      "the host named its own file, so nothing here may resolve out of the gem"
  end

  # THE HUB'S WAY BACK, asserted so the CHANGELOG's instruction is known to work
  # rather than merely written down. McRitchie Studio owns this mark; it opts in
  # by naming it, and the asset still ships here so the line resolves today.
  test "the hub opts back in by naming the mark it owns" do
    Studio::EmailCatalog.register("magic_link", logo: "emails/logo-horizontal.png")

    marks = doc.css("img").filter_map { |img| engine_file_behind(img["src"]) }

    assert_equal [ wordmark_digest ], marks.map { |file| Digest::SHA256.file(file).hexdigest },
      "a host naming the wordmark must actually get the wordmark"
  end
end
