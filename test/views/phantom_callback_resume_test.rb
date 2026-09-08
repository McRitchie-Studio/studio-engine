require "bundler/setup"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"
require "open3"
require "json"

# The callback's REDIRECT-TRANSPORT dispatch, executed rather than grepped.
#
# WHAT IS AT STAKE. This file is what production mobile sign-in returns to
# TODAY, on the legacy phantom_dl_* path. The new branch sits AHEAD of that
# path, so getting its guard wrong does not degrade a new feature — it breaks
# the one thing phones can already do. That is why the guard is tested by
# RUNNING it across every state a real host can be in, rather than by asserting
# that some source text exists.
#
# A source-text assertion cannot tell a live branch from a dead one, and this
# house has been bitten by exactly that (see the secret-redaction test in
# turf-monster, which is where this extraction technique comes from). So the
# branch is pulled out of the view VERBATIM and executed against stubs.
class PhantomCallbackResumeTest < ActiveSupport::TestCase
  CALLBACK_PATH = File.expand_path(
    "../../app/views/solana_sessions/phantom_callback.html.erb", __dir__
  ).freeze

  # Pull the dispatch out of the view verbatim, so the test executes the shipped
  # code rather than a paraphrase of it.
  def dispatch_source
    view = File.read(CALLBACK_PATH)
    branch = view[/var studio = window\.SolanaStudio;.*?\n    return;\n  \}/m]
    assert branch, "could not extract the resume dispatch from the callback view"
    branch
  end

  # `studio:` nil | :no_journal | :pending
  # `resume:` what walletOps.resume resolves or rejects with
  def run_dispatch(studio:, resume: { "pending" => true, "done" => true })
    studio_js =
      case studio
      when nil then "var SolanaStudioStub = null;"
      when :no_journal
        "var SolanaStudioStub = { walletJournal: { peek: function() { return null; } }, " \
          "walletOps: { resume: function() { calls.push('resume'); return Promise.resolve({}); } } };"
      else
        settle = resume.is_a?(Hash) && resume["__reject"] ?
          "Promise.reject(Object.assign(new Error(#{resume['message'].to_json}), { rejected: true }))" :
          "Promise.resolve(#{resume.to_json})"
        "var SolanaStudioStub = { walletJournal: { peek: function() { return { v: 1, step: 'connect' }; } }, " \
          "walletOps: { resume: function(p, o) { calls.push('resume'); navigateFn = o.navigate; return #{settle}; } } };"
      end

    script = <<~JS
      var calls = [];
      var errors = [];
      var navigateFn = null;
      function dbg() {}
      function showError(m) { errors.push(m); calls.push('showError'); }
      var params = { get: function() { return null; } };
      #{studio_js}
      global.window = { SolanaStudio: SolanaStudioStub, location: { href: '' } };
      Object.defineProperty(global.window.location, 'href', {
        set: function(v) { calls.push('navigate:' + v); }, get: function() { return ''; }, configurable: true
      });

      // The extracted branch ends in `return;` INSIDE its own if. So the line
      // after it runs exactly when the branch did NOT take — which is the
      // fall-through to the legacy path, and the thing worth asserting.
      var branchHandled = true;
      (function () {
        #{dispatch_source}
        branchHandled = false;   // reached only when the guard was false
      })();

      setTimeout(function () {
        console.log(JSON.stringify({ calls: calls, errors: errors, branchHandled: branchHandled }));
      }, 10);
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
  end

  test "a host without the transport scripts falls through to the legacy path" do
    # THE COMPATIBILITY GUARANTEE. turf-monster does not load wallet_ops.js yet,
    # and its mobile sign-in must behave exactly as it did before this change.
    result = run_dispatch(studio: nil)

    assert_equal [], result["calls"], "nothing may run when the transport is absent"
    assert_equal false, result["branchHandled"],
                 "the branch must fall through — the legacy path owns this request"
  end

  test "a host with the scripts but no pending journal falls through too" do
    # A user mid-round-trip across a deploy started under the OLD keys. Requiring
    # an actual journal means they finish on the path they started, rather than
    # meeting a resumer with nothing to resume.
    result = run_dispatch(studio: :no_journal)

    refute_includes result["calls"], "resume", "resume must not be called with nothing pending"
    assert_equal false, result["branchHandled"], "it must fall through to the legacy path"
  end

  test "a pending journal is resumed and a completed intent lands somewhere" do
    result = run_dispatch(studio: :pending, resume: { "pending" => true, "done" => true })

    assert_includes result["calls"], "resume"
    assert(result["calls"].any? { |c| c.start_with?("navigate:") }, "a finished intent must land the user somewhere")
  end

  test "a suspended hop does not also redirect" do
    # resume already navigated to the next wallet hop. Redirecting here too would
    # race it, and the user would land back on the callback with the journal
    # already consumed.
    result = run_dispatch(studio: :pending, resume: { "pending" => true, "suspended" => true })

    assert_includes result["calls"], "resume"
    refute(result["calls"].any? { |c| c.start_with?("navigate:") },
           "the next hop is already navigating — this document must not race it")
    # AND IT MUST BE SILENT. Found by mutation testing: deleting the suspended
    # guard produced no redirect (so the assertion above still passed) but DID
    # fall through to the no-pending-request error — a scary message on a hop
    # that is working perfectly. A suspended hop says nothing.
    refute_includes result["calls"], "showError",
                    "a hop in progress must not report a failure"
  end

  test "a rejection surfaces the wallet's own words" do
    result = run_dispatch(studio: :pending,
                          resume: { "__reject" => true, "message" => "User rejected the request" })

    assert_includes result["errors"], "User rejected the request",
                    "a user rejection must reach the screen as itself, not as a generic failure"
  end

  test "nothing pending after all is reported rather than silently swallowed" do
    # peek() said there was a journal a moment ago; resume found none. A race —
    # a reload, a second tab. The honest answer is to start over, not a blank page.
    result = run_dispatch(studio: :pending, resume: { "pending" => false })

    assert_includes result["calls"], "showError"
    assert(result["errors"].first.match?(/no pending/i), "got: #{result['errors'].first}")
  end
end
