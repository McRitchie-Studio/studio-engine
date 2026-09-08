source "https://rubygems.org"

gemspec

# nokogiri: historically pinned to 1.18.10 here while the ecosystem was on
# Ruby 3.1.7 (nokogiri >= 1.19.x requires Ruby 3.2+). The ecosystem is now on
# Ruby 3.3.11, so a plain `bundle update` resolves the patched nokogiri
# (>= 1.19.3, the line that fixed 3 CVEs: 1 HIGH regex-backtracking + 2 MEDIUM
# XSLT / xmlC14NExecute). This gem still does NOT declare nokogiri as a runtime
# dependency — it arrives via Rails in the consuming app. Tracked in
# SECURITY-AUDIT-2026-05-17.md.
#
# It is also not declared as a test dependency, but test/views/user_nav_test.rb
# now requires it directly to walk rendered markup. That resolves today because
# actionview pulls it in via rails-dom-testing; if that ever stops being true
# the suite fails loudly with a LoadError rather than silently skipping, so
# declare it here at that point rather than pre-emptively pinning it.

group :development, :test do
  # SQLite drives the test/dummy Rails app's in-memory database (see
  # test/integration/engine_rails_8_1_boot_test.rb), which boots the engine
  # against a real Rails app so we catch Rails-version incompatibilities in the
  # engine's ActiveRecord/Railtie surfaces. Not a runtime dependency — the
  # consuming apps bring their own database adapter. Rails 8.1 needs sqlite3 ~> 2.1.
  gem "sqlite3", ">= 2.1"

  # Puma serves the dummy host for the BROWSER LANE (e2e/boot.rb). The gem ships no
  # config.ru and test/dummy has no bin/rails, so the lane boots Puma::Server around
  # Rails.application directly rather than growing Rails-app scaffolding inside a
  # test fixture. Not a runtime dependency — consuming apps bring their own server.
  gem "puma", ">= 6.0"
end

# solana-studio backs the style guide's THREE web3 specimens (Connect wallet and
# the two Sign Wallet cards). Those partials used to live here, in
# app/views/studio/modals; the two-template split moved them to the gem —
# BASE is studio-engine + mcritchie-studio, WEB3 ADD is solana-studio +
# turf-monster — because, as the call was made, "the real op sec vector is
# managing sessions safely. Anything wallet based should be in the app."
#
# DEVELOPMENT AND TEST ONLY, and deliberately NOT a gemspec runtime dependency.
# Declaring it there would push a Solana stack onto every BASE consumer
# (acquisition-studio, mcritchie-industries, moms-app mount this engine and
# bundle no solana-studio), which is precisely the coupling the split removed.
# It is here so the DUMMY app can resolve the gem's partials and the style guide
# renders the real shipped cards rather than a fork of them.
#
# There is no dependency cycle: solana-studio's GEMSPEC declares only ed25519.
# It lists studio-engine in its own Gemfile, dev-only, which Bundler never reads
# when solana-studio is consumed as a gem.
#
# The style guide self-gates on the partial RESOLVING (style/_modals.html.erb),
# so an app without this gem renders /admin/style with the web3 cards badged
# rather than raising a missing-template error.
#
# THE CONSTRAINT STAYS OPEN-ENDED, AND THAT IS A DECISION, NOT AN OVERSIGHT.
# ">= 0.5.3" is a FLOOR: 0.5.2 shipped the credential partial without
# solana_studio/modals/_wallet_connect, which the web3 capability gate requires,
# so 0.5.3 is the first version that can draw the button at all. Above it this
# engine deliberately claims no ceiling. It is the BASE half of the split; the
# bolt-on is the consumer's choice, and an engine that pinned the bolt-on more
# tightly than the app bolting it on would be dictating upward. Concretely: a
# pessimistic "~> 0.5.3" here would be NARROWER than mcritchie-studio's own
# "~> 0.5", so this dev-only dependency would start constraining a resolution it
# does not own.
#
# WHAT ACTUALLY WENT WRONG, and it was the LOCK, not the constraint. The lock sat
# on 0.5.3 while both consumers shipped 0.5.7 — four patch releases — and nothing
# was red, because engine CI installs with `bundler-cache: true` and never
# resolves fresh. Meanwhile test/views/style_web3_specimens_test.rb exists to
# prove "the style guide renders the REAL gem cards" and reads them off whatever
# the LOCK resolved. Behind, that guard certifies a card no consumer receives; it
# still passes, and only its MEANING has changed. (Measured on this span: the
# gem's whole app/ tree was byte-identical 0.5.3 -> 0.5.7, so this instance cost
# nothing — which is precisely why it went four releases unnoticed.)
#
# SO THE FIX IS A GATE, NOT A PIN. bin/gem-drift-check fails when this engine's
# lock resolves an OLDER solana-studio than a consumer's, and consumer-ci.yml
# runs it — the only lane holding two repos' lockfiles at once. Direction is
# one-way: engine behind fails, engine ahead or level passes, a consumer
# bundling no solana-studio is a skip. Guarded by
# test/lib/gem_drift_check_test.rb.
#
# READ THE CONSUMER AS A MESSENGER, not as the target. The invariant is that
# this engine resolves the LATEST RELEASED solana-studio. A consumer's lock is
# compared only because it is the one newer-release fact on disk — the gate is
# stdlib-only and makes no network call, deliberately, so it cannot ask the
# registry directly. A consumer being ahead is EVIDENCE of a release this engine
# missed, never itself the thing to catch up to.
#
# AND THE GATE ALONE WAS NOT ENOUGH. Enforcement only reddens; a human still had
# to do the bump. Measured 2026-09-07: that human was late five times in ONE DAY
# — by 3h, 2h20m, 14h15m and 1h10m — and the worst case was not the longest but
# the fastest, a lock that went stale 36 minutes after the previous fix was
# committed. While it is stale EVERY open engine PR is red, over a line no PR
# author owns. So .github/dependabot.yml now opens the bump PR daily (scoped to
# solana-studio ALONE, so this repo never inherits the third-party graveyard),
# and .github/workflows/engine-lock-automerge.yml merges it when — and only
# when — all four of bin/lock-bump-mergeable's conditions hold. A breaking bump
# still stops, stays open and red, and still waits for a human.
group :development, :test do
  gem "solana-studio", ">= 0.5.3"
end
