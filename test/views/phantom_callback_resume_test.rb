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

  # The status line's opening text, read from the view rather than restated, so
  # the resume tests start from exactly what a real page starts from.
  def rendered_default_status
    text = File.read(CALLBACK_PATH)[%r{<p id="phantom-status"[^>]*>(.*?)</p>}m, 1]
    assert text, "could not find the #phantom-status line in the callback view"
    text
  end

  # `studio:` nil | :no_journal | :pending
  # `resume:` what walletOps.resume resolves or rejects with, or :never for a
  #           server leg still running when the page is read
  # `push:`   event details the intent dispatches WHILE resume runs. Dispatched
  #           synchronously inside resume, because that is when the real one
  #           runs complete(): resume calls it in the same tick, so a listener
  #           installed after resume would miss every push.
  def run_dispatch(studio:, resume: { "pending" => true, "done" => true }, push: [])
    studio_js =
      case studio
      when nil then "var SolanaStudioStub = null;"
      when :no_journal
        "var SolanaStudioStub = { walletJournal: { peek: function() { return null; } }, " \
          "walletOps: { resume: function() { calls.push('resume'); return Promise.resolve({}); } } };"
      else
        settle =
          if resume == :never
            "new Promise(function() {})"
          elsif resume.is_a?(Hash) && resume["__reject"]
            "Promise.reject(Object.assign(new Error(#{resume['message'].to_json}), { rejected: true }))"
          else
            "Promise.resolve(#{resume.to_json})"
          end
        pushes = push.map do |detail|
          "document.dispatchEvent(new CustomEvent('studio:wallet-progress', { detail: #{detail.to_json} }));"
        end.join(" ")
        "var SolanaStudioStub = { walletJournal: { peek: function() { return { v: 1, step: 'connect' }; } }, " \
          "walletOps: { resume: function(p, o) { calls.push('resume'); navigateFn = o.navigate; " \
          "#{pushes} return #{settle}; } } };"
      end

    script = <<~JS
      var calls = [];
      var errors = [];
      var navigateFn = null;
      function dbg() {}
      function showError(m) { errors.push(m); calls.push('showError'); }
      var params = { get: function() { return null; } };
      // The status line, seeded with the view's own opening text. innerHTML is a
      // separate slot on purpose: a push written as markup lands there and leaves
      // textContent unchanged, so the assertions below catch it.
      var statusEl = { textContent: #{rendered_default_status.to_json}, innerHTML: '' };
      global.document = new EventTarget();
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
        console.log(JSON.stringify({ calls: calls, errors: errors, branchHandled: branchHandled,
                                     status: statusEl.textContent }));
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

  # --- the progress seam: the intent speaks, the page listens -------------
  #
  # THE DEFECT. The status line changed only on the legacy branch, past this
  # one's early return, so a redirect-transport transaction read one unchanging
  # sentence for its whole server leg — 18 seconds measured on a QA iPhone for a
  # contest entry. The host intent knows what the server is doing; this page has
  # the only surface left on screen. The page listens for studio:wallet-progress
  # and the intent dispatches it, so neither learns the other's job.

  NEUTRAL_STATUS = "Processing your wallet's response..."

  test "a progress push from the intent is on screen while the server leg runs" do
    # resume never settles: the page is read MID-LEG, which is the 18 seconds
    # the user actually sits through.
    result = run_dispatch(studio: :pending, resume: :never,
                          push: [{ "text" => "Cosigning and submitting to Solana..." }])

    assert_equal "Cosigning and submitting to Solana...", result["status"],
                 "the intent pushed its progress and the status line did not show it"
    assert_empty result["errors"], "a leg still running is not a failure"
  end

  test "the latest push is the one on screen" do
    result = run_dispatch(studio: :pending, resume: :never,
                          push: [{ "text" => "Cosigning..." }, { "text" => "Confirming on chain..." }])

    assert_equal "Confirming on chain...", result["status"]
  end

  test "with no push the status line keeps the wallet-neutral default" do
    # An intent that says nothing, and every host that has not adopted the seam
    # yet. The page must still tell the truth, and the truth names no vendor.
    result = run_dispatch(studio: :pending, resume: :never)

    assert_equal NEUTRAL_STATUS, result["status"],
                 "with nothing pushed, the status line must hold the view's wallet-neutral default"
  end

  test "an empty or non-text push leaves the default standing" do
    # A blank status line reads as a hang, which is the defect itself. So a push
    # with nothing to say, or a detail of the wrong shape, changes nothing.
    result = run_dispatch(studio: :pending, resume: :never,
                          push: [{ "text" => "   " }, { "text" => 42 }, {}])

    assert_equal NEUTRAL_STATUS, result["status"],
                 "a push with no text replaced the default; the user now reads nothing"
  end

  test "nothing pending after all is reported rather than silently swallowed" do
    # peek() said there was a journal a moment ago; resume found none. A race —
    # a reload, a second tab. The honest answer is to start over, not a blank page.
    result = run_dispatch(studio: :pending, resume: { "pending" => false })

    assert_includes result["calls"], "showError"
    assert(result["errors"].first.match?(/no pending/i), "got: #{result['errors'].first}")
  end
end
