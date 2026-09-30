# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/studio/link_preview"
require "tmpdir"
require "fileutils"

# [unit] Studio::LinkPreview — the pure half of the link-preview primitive: the
# preview-bot matcher, the resolution chain (page override, operator default,
# static fallback), and the slim document a preview fetcher is served.
class StudioLinkPreviewTest < Minitest::Test
  LP = Studio::LinkPreview

  # The real iMessage fetcher UA (Apple LinkPresentation), as measured on the
  # imessage-link-preview-fix probe: an old Safari suffixed with the Facebook
  # and X fetcher names.
  IMESSAGE_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 " \
                "(KHTML, like Gecko) Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.0"

  BOTS = {
    "iMessage" => IMESSAGE_UA,
    "Facebook" => "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
    "Facebot" => "Facebot",
    "X" => "Twitterbot/1.0",
    "Discord" => "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)",
    "Slack" => "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
    "LinkedIn" => "LinkedInBot/1.0 (compatible; Mozilla/5.0; Apache-HttpClient +http://www.linkedin.com)",
    "WhatsApp" => "WhatsApp/2.23.20.0",
    "Telegram" => "TelegramBot (like TwitterBot)",
    "Applebot" => "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.1.1 Safari/605.1.15 (Applebot/0.1)",
    "Skype" => "Mozilla/5.0 (Windows NT 6.1; WOW64) SkypeUriPreview Preview/0.5",
    "Reddit" => "Mozilla/5.0 (compatible; redditbot/1.0; +http://www.reddit.com/feedback)",
    "Embedly" => "Mozilla/5.0 (compatible; Embedly/0.2; +http://support.embed.ly/)"
  }.freeze

  PEOPLE = {
    "iPhone Safari" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
    "Chrome" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36",
    "Facebook in-app" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/480.0.0]",
    "LinkedIn in-app" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [LinkedInApp]/9.30",
    "X in-app" => "Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Twitter for iPhone/10.60",
    "curl" => "curl/8.7.1"
  }.freeze

  # --- the bot matcher -----------------------------------------------------

  def test_every_named_preview_fetcher_is_a_bot
    BOTS.each { |who, ua| assert LP.bot?(ua), "#{who} must get the slim document" }
  end

  def test_people_and_in_app_browsers_are_not_bots
    PEOPLE.each { |who, ua| refute LP.bot?(ua), "#{who} must get the full page" }
  end

  def test_blank_and_nil_are_not_bots
    refute LP.bot?(nil)
    refute LP.bot?("")
    refute LP.bot?("   ")
  end

  def test_match_is_case_insensitive
    assert LP.bot?("DISCORDBOT/2.0")
  end

  # --- the resolution chain ------------------------------------------------

  def test_page_override_beats_default_and_static
    got = LP.resolve(site_name: "App", titles: ["Contest", "Default title"], descriptions: ["Page desc"],
                     page_images: ["https://cdn/banner.png"], default_image: "https://cdn/default.png",
                     static_image: "/og.png")

    assert_equal "Contest", got[:title]
    assert_equal "Page desc", got[:description]
    assert_equal "https://cdn/banner.png", got[:image]
    assert_equal :page, got[:image_source]
  end

  def test_admin_default_answers_when_the_page_says_nothing
    got = LP.resolve(site_name: "App", titles: [nil, "Operator title"], descriptions: ["", "Operator desc"],
                     page_images: [nil], default_image: "https://cdn/default.png", static_image: "/og.png")

    assert_equal "Operator title", got[:title]
    assert_equal "Operator desc", got[:description]
    assert_equal "https://cdn/default.png", got[:image]
    assert_equal :default, got[:image_source]
  end

  # The override rule: a page that offers an image it does not have (a user with
  # no avatar) is a blank rung, and falls through to the default.
  def test_override_with_missing_image_falls_back_to_the_default
    got = LP.resolve(site_name: "App", titles: ["Alex"], page_images: [nil, "  "],
                     default_image: "https://cdn/default.png")

    assert_equal "Alex", got[:title]
    assert_equal "https://cdn/default.png", got[:image]
    assert_equal :default, got[:image_source]
  end

  def test_static_fallback_when_nothing_is_uploaded
    got = LP.resolve(site_name: "App", static_image: "/og.png")

    assert_equal "App", got[:title], "the site name is the last title rung"
    assert_nil got[:description], "no description rung means no tag, never an empty one"
    assert_equal "/og.png", got[:image]
    assert_equal :static, got[:image_source]
  end

  def test_no_image_anywhere_is_none
    got = LP.resolve(site_name: "App")

    assert_nil got[:image]
    assert_equal :none, got[:image_source]
  end

  def test_absolute_url
    assert_equal "https://app.test/og.png", LP.absolute_url("/og.png", base_url: "https://app.test/")
    assert_equal "https://cdn.test/a.png", LP.absolute_url("//cdn.test/a.png", base_url: "https://app.test")
    assert_equal "https://cdn.test/a.png", LP.absolute_url("https://cdn.test/a.png", base_url: "https://app.test")
    assert_nil LP.absolute_url(" ", base_url: "https://app.test")
  end

  # --- does the app write its own tags? ------------------------------------

  def test_own_tag_file_finds_an_app_template_that_writes_og_tags
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "layouts"))
      File.write(File.join(root, "layouts/application.html.erb"), "<title>x</title>")
      assert_nil LP.own_tag_file(root), "an app with no og tags of its own"

      seo = File.join(root, "layouts/_seo.html.erb")
      File.write(seo, %(<meta property="og:title" content="<%= page.title %>">))
      assert_equal seo, LP.own_tag_file(root), "cyvasse's _seo shape"
    end
  end

  def test_own_tag_file_is_nil_for_a_missing_root
    assert_nil LP.own_tag_file(nil)
    assert_nil LP.own_tag_file("/nonexistent/app/views")
  end

  # --- the slim document ---------------------------------------------------

  def page(head_extra: "", body: "<p>hello</p>")
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <title>Contest &amp; Co</title>
        <meta name="csrf-token" content="secret-token">
        <meta property="og:title" content="App title">
        #{head_extra}
        <meta property="og:title" content="Engine title">
        <meta name="description" content="A description">
        <meta property="og:image" content="https://cdn/a.png">
        <meta name="twitter:card" content="summary_large_image">
        <link rel="stylesheet" href="/app.css">
        <link rel="icon" href="/favicon.png">
        <script>var s = '<meta property="og:title" content="from a script">';</script>
        <style>body { color: red }</style>
      </head>
      <body>#{body}</body>
      </html>
    HTML
  end

  def test_slim_document_keeps_identity_tags_and_drops_everything_executable
    doc = LP.slim_document(page, url: "https://app.test/c/1")

    assert_includes doc, "<title>Contest &amp; Co</title>"
    assert_includes doc, %(<meta name="description" content="A description">)
    assert_includes doc, %(<meta property="og:image" content="https://cdn/a.png">)
    assert_includes doc, %(<meta name="twitter:card" content="summary_large_image">)
    assert_includes doc, %(<link rel="icon" href="/favicon.png">)
    assert_includes doc, %(<html lang="en">)
    refute_includes doc, "<script"
    refute_includes doc, "<style"
    refute_includes doc, "stylesheet"
    refute_includes doc, "secret-token", "a per-session CSRF token has no business in a cached preview"
    refute_includes doc, "<p>hello</p>", "the page body is not carried"
    assert_includes doc, %(<a href="https://app.test/c/1">)
  end

  # DUPLICATE-SAFE: an app that emits its own og tags before the engine's keeps
  # its own, once.
  def test_slim_document_keeps_the_first_of_a_duplicated_tag
    doc = LP.slim_document(page)

    assert_equal 1, doc.scan('property="og:title"').size
    assert_includes doc, %(content="App title")
    refute_includes doc, "Engine title"
    refute_includes doc, "from a script", "a tag inside a script is not a tag"
  end

  def test_slim_document_is_under_the_imessage_limit_when_the_page_is_not
    huge = page(body: "<script>#{"x" * 1_300_000}</script><template>#{"y" * 300_000}</template>")
    assert_operator huge.bytesize, :>, LP::MAX_DOCUMENT_BYTES

    doc = LP.slim_document(huge)

    assert_operator doc.bytesize, :<, LP::MAX_DOCUMENT_BYTES
    assert_operator doc.bytesize, :<, 2_000
  end

  # A head that is itself over the limit (an inline data: icon) still comes in
  # under it, keeping the tags an unfurl card is made of.
  def test_an_oversized_head_is_cut_to_the_card_tags
    fat_icon = %(<link rel="icon" href="data:image/png;base64,#{"A" * 1_100_000}">)
    doc = LP.slim_document(page(head_extra: fat_icon).sub(%(<link rel="icon" href="/favicon.png">), ""))

    assert_operator doc.bytesize, :<, LP::MAX_DOCUMENT_BYTES
    assert_includes doc, %(property="og:image")
    assert_includes doc, %(name="description")
  end
end
