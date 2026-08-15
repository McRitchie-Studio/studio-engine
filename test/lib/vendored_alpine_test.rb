# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] Alpine ships FROM THE ENGINE, pinned, and never from a CDN.
#
# WHAT THIS REPLACED. layouts/studio/_head.html.erb loaded Alpine as
#
#   <script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js">
#
# — a floating major range, fetched from a third party at page load, for the library
# every chip, drawer, modal and board filter in the fleet depends on. Two CI runs on
# one SHA could execute different builds; production interactivity depended on
# jsDelivr; and an upgrade arrived with NO DIFF, because nothing in the repo changed
# when it did. The last one is why this file exists: a dependency that can change
# without a commit cannot be reviewed, and cannot be bisected.
#
# THREE FAILURE MODES, one test each, because they break in different places:
#   * the CDN tag creeping back (the thing being fixed)
#   * the precompile entry missing — Sprockets hosts (mcritchie-studio, turf-monster)
#     serve NOTHING without it, while propshaft hosts happily ignore the list, so
#     this breaks on exactly half the fleet and looks fine on the other half
#   * the pin drifting between the file header and the view comment, which would
#     leave the next upgrader trusting whichever one they happened to read
class VendoredAlpineTest < Minitest::Test
  ROOT   = File.expand_path("../..", __dir__)
  HEAD   = File.join(ROOT, "app/views/layouts/studio/_head.html.erb")
  ENGINE = File.join(ROOT, "lib/studio/engine.rb")
  ASSET  = File.join(ROOT, "app/assets/javascripts/studio/alpine.js")

  def head    = @head ||= File.read(HEAD)
  def engine  = @engine ||= File.read(ENGINE)

  # The head WITHOUT its ERB comments. These assertions are about what the browser
  # receives, and the comment above the include tag deliberately QUOTES the CDN line
  # it replaced — that prose is the most useful part of the fix, and a guard that
  # forbade naming the thing it removed would force the next reader to go digging in
  # git history for the reason.
  def rendered_head = head.gsub(/<%#.*?%>/m, "")

  def test_the_head_loads_no_script_from_a_third_party
    # Only SCRIPT srcs — the Google Fonts stylesheet/preconnect above is a separate
    # decision with a separate trade-off, and folding it in here would make this
    # test fail for a reason it is not about.
    remote = rendered_head.scan(/<script[^>]+src=["'](https?:[^"']+)["']/i).flatten

    assert_empty remote,
                 "the head loads script(s) from a third party: #{remote.inspect}. Vendor it into " \
                 "app/assets/javascripts/studio/ and ship it through the asset pipeline, as alpine, " \
                 "canvas_confetti and sortable already are."
  end

  def test_alpine_is_included_from_the_asset_pipeline
    assert_match(/javascript_include_tag\s+["']studio\/alpine["']/, rendered_head,
                 "the head must include studio/alpine through the pipeline")
  end

  # THE HALF-THE-FLEET TRAP. Without this entry Sprockets hosts raise on the include
  # tag while propshaft hosts serve it fine, so a missing line here reads as "works
  # on my app" right up until the other two 500.
  def test_alpine_is_precompiled
    assert_match(%r{^\s*studio/alpine\.js\s*$}, engine,
                 "studio/alpine.js must be in the engine's assets.precompile list, or Sprockets " \
                 "hosts (mcritchie-studio, turf-monster) will not serve it")
  end

  def test_the_vendored_file_is_present_and_is_alpine
    assert File.exist?(ASSET), "the vendored Alpine build is missing"
    body = File.read(ASSET)

    assert_operator body.bytesize, :>, 30_000, "the vendored file is too small to be an Alpine build"
    assert_includes body, "Alpine", "the vendored file does not look like Alpine"
  end

  # The pin is written in two places on purpose — the file says what it IS, the view
  # says what it EXPECTS — so this asserts they agree. A drift here is silent: both
  # documents keep reading plausibly, and only one of them is true.
  def test_the_pinned_version_agrees_between_the_asset_and_the_view
    in_asset = File.read(ASSET)[/Alpine\.js (\d+\.\d+\.\d+)/, 1]
    in_head  = head[/PINNED AT (\d+\.\d+\.\d+)/, 1]

    refute_nil in_asset, "the vendored file's header must name its version"
    refute_nil in_head,  "the view comment must name the pinned version"
    assert_equal in_asset, in_head,
                 "the vendored build says #{in_asset} and the view says #{in_head} — update both"
  end

  def test_the_pin_is_exact_not_a_range
    assert_nil rendered_head[/alpinejs@3\.x\.x/],
               "a floating range is what this replaced: it lets the dependency change with no diff"
  end
end
