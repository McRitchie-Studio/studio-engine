# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [component] The shared first-name onboarding step, ported from turf-monster so
# McRitchie Studio can ask the same question.
#
# What this primitive is, and is NOT:
#   * It owns ONE step. The host owns the SEQUENCE — turf walks welcome → first
#     name → age → wallet; a hub app may ask nothing else. So the partial never
#     opens another modal: it dispatches its done_event with the steps the SERVER
#     said remain and closes.
#   * Every endpoint and label is a LOCAL with a default, so a host that mounts
#     it under different routes does not fork the partial.
class OnboardingFirstNameTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ENGINE_ROOT, "app/views")])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
  end

  def render_first_name(**locals)
    view.render(partial: "studio/modals/onboarding/first_name", locals: locals)
  end

  def doc(**locals)
    Nokogiri::HTML::DocumentFragment.parse(render_first_name(**locals))
  end

  # --- The single-root + quoting contract -------------------------------------

  test "renders exactly ONE root element" do
    # The modal host clones this from a <template x-if>; Alpine silently mounts
    # NOTHING when the template's content has multiple roots.
    frag = doc
    roots = frag.children.reject { |n| n.text? && n.text.strip.empty? }
    assert_equal 1, roots.size, "expected a single root, got: #{roots.map(&:name).inspect}"
  end

  test "the x-data attribute contains no double quotes" do
    # A double quote inside the double-quoted x-data closes it early and the
    # component mounts as a SILENT no-op — the markup still renders, so every
    # string assertion below would still pass while the modal is dead in a
    # browser. This exact bug has bitten twice in turf (PR #30, then the wallet
    # modal), which is why the port carries the guard with it.
    #
    # Read the RAW markup, NEVER Nokogiri's parsed attribute. An HTML parser
    # TERMINATES a double-quoted value at the first unescaped `"`, so the parsed
    # string can never contain one — `at_css("[x-data]")["x-data"]` passes on the
    # exact input this test exists to catch (mutation-checked in review, 2026-08-13:
    # a literal quote inside x-data left all 11 tests green). The closing `"` is
    # pinned to the newline + `class=` that really ends the attribute, which is
    # what makes a stray quote land INSIDE the captured span. Same shape as turf's
    # test/controllers/onboarding_gallery_test.rb, the guard this port came from.
    x_data = render_first_name[/<div x-data="(.*?)"\s*\n\s*class=/m, 1]
    assert x_data.present?, "could not locate the x-data attribute — did the root element change?"
    assert_not_includes x_data, '"',
                        "a double quote inside x-data kills the component in the browser"
  end

  # --- Host configurability ---------------------------------------------------

  test "defaults to the conventional onboarding endpoints" do
    html = render_first_name
    assert_includes html, "/onboarding/first_name"
    assert_includes html, "/onboarding/skip_first_name"
  end

  test "a host can mount it under its own routes without forking the partial" do
    html = render_first_name(submit_path: "/profile/name", skip_path: "/profile/name/skip")
    assert_includes html, "/profile/name"
    assert_includes html, "/profile/name/skip"
    assert_not_includes html, "/onboarding/first_name"
  end

  test "a host can retarget the modal store and the done event" do
    # The living style guide mounts a page-scoped host (dsModals) rather than the
    # app-level one, so a hard-coded store name would make it unpreviewable.
    html = render_first_name(modal_store: "dsModals", done_event: "ds-step-done")
    assert_includes html, "$store.dsModals"
    assert_includes html, "ds-step-done"
    assert_not_includes html, "$store.modals."
  end

  test "copy and field bounds are host-overridable" do
    html = render_first_name(heading: "Your name?", subtext: "For your receipts.",
                             placeholder: "Sam", max_length: 12)
    assert_includes html, "Your name?"
    assert_includes html, "For your receipts."
    assert_equal "Sam", doc(placeholder: "Sam").at_css("input")["placeholder"]
    assert_equal "12", doc(max_length: 12).at_css("input")["maxlength"]
  end

  test "the progress pill renders only when a host asks for it" do
    assert_nil doc.at_css(".progress-pill, [data-progress-pill]"),
               "no pill unless the host passes one" if doc.at_css("[data-progress-pill]")
    with_pill = render_first_name(progress: [2, 3])
    # The shared block renders segments; assert it appeared at all.
    assert_operator with_pill.length, :>, render_first_name.length,
                    "passing progress: should render additional markup"
  end

  # --- The behaviours the step must always have -------------------------------

  test "BOTH skip affordances are present and both call skip()" do
    # The × must SKIP, not merely close: a close that abandons the chain silently
    # is how a host ends up with a step nobody can answer again.
    html = render_first_name
    # Asserted against the RAW markup, not parsed attributes: Nokogiri's HTML
    # parser drops Alpine's `@click` (not a legal HTML attribute-name start), so
    # a node["@click"] read returns nil and the assertion would fail on the
    # parser rather than on the component.
    assert_includes html, "Skip for now"
    assert_includes html, %(aria-label="Skip")
    assert_equal 2, html.scan(%(@click="skip()")).size,
                 "both the link and the × must call skip(), not close"
  end

  test "the field is focused on open" do
    # The HTML autofocus attribute does nothing for a modal mounted from a
    # <template x-if> after the document parsed — the focus has to come from
    # Alpine.
    input = doc.at_css("input#onboarding-first-name")
    assert input, "expected the first-name input"
    assert_includes input["x-init"].to_s, "focus"
  end

  test "it reports upward and closes rather than opening anything itself" do
    html = render_first_name
    assert_includes html, "onboarding-step-done", "must announce what remains"
    assert_includes html, "$store.modals.close()", "must close itself"
    assert_not_includes html, ".open(", "the host owns the sequence; this step opens nothing"
  end

  test "the save posts JSON with a CSRF token" do
    html = render_first_name
    assert_includes html, "X-CSRF-Token"
    assert_includes html, "application/json"
  end
end
