# Studio Engine Release Runbook

This repo publishes the shared `studio-engine` gem. Consumer apps pull released
versions from RubyGems with a two-segment pessimistic pin — `gem "studio-engine",
"~> 0.56"` in turf-monster today.

**A two-segment `~>` admits every 0.x below 1.0**, so the number in a consumer's
Gemfile is a FLOOR, not a statement of what it runs. The consumers write that
floor's reason into the pin comment (see turf-monster's, which records which
engine version each adopted primitive actually requires). Read the lockfile, not
the pin, for what resolves.

Do not publish, push tags, deploy consumers, or rotate credentials from an
agent session without explicit approval.

## What is currently released

**This section deliberately names no version.** It used to enumerate the live
release and its features in prose, and it rotted roughly fifty minors — it still
claimed `v0.6.0` was current while RubyGems served `0.56.1`, and it attributed
capabilities to `0.5.6` / `0.5.8` / `0.5.10`. A version list in a runbook is a
promise to hand-edit prose on every single release, and that promise is not kept.
So the runbook now points at the sources that update themselves:

```bash
gem list -r studio-engine --all | head -1   # every published version, newest first
git tag --list 'v*' --sort=-v:refname | head -1   # what this repo last tagged
```

- **What changed in a release** → `CHANGELOG.md`, which every engine PR updates
  under `Unreleased` as it goes (the changelog is not gated by `dor-check`).
- **What a given consumer resolves** → that app's `Gemfile.lock`, never its
  Gemfile pin.
- **Why a consumer's floor is where it is** → its Gemfile pin COMMENT, which is
  where the adopting task records the primitive that set the floor.

If you need the shape of a release before publishing it, read the candidate's
membership on the board rather than this file.

## Preflight

Run this before any engine PR is considered ready:

```bash
cd /Users/alex/projects/studio-engine
bin/release-check
```

For a local package sanity check without writing artifacts into the repo:

```bash
bin/release-check --build
```

The build artifact is written to `/tmp/studio-engine-release-check/`.

## Who sets the version

**Not the builder.** A version is a property of the RELEASE, not of any one PR:
N pull requests riding one release candidate publish exactly **one** version, so
no individual PR can know the right answer when it is written. McRitchie Studio's
`bin/dor-check` **refuses any PR whose diff touches `lib/studio/version.rb`** and
will not let the task advance.

So the two audiences below are separate. Read the one you are.

### If you are building an engine change

1. Confirm the diff is limited to the intended engine changes.
2. **Do not touch `lib/studio/version.rb`.** Updating `CHANGELOG.md` under the
   `Unreleased` heading is fine and encouraged — the changelog is *not* gated.
3. Run `bin/release-check` (or `bin/release-check --build` for a package sanity
   check).
4. Open your PR into `accepted` like any other task. You are done; the release
   assigns the number.

If your change is **breaking**, say so on the task rather than versioning it:
`bin/task update <task-slug> --gem-bump major`.

### If you are the release conductor

**`bin/release prepare` allocates the version. Do not set it by hand.** This
runbook used to say the opposite — that `Release::GemVersion` existed but
"nothing calls it yet", and that you should compute the next version yourself and
commit it onto `accepted`. That is no longer true, and following it now COLLIDES
with the automation: `bin/release.rb` calls `Release::GemVersion.allocation`
during prepare, and a hand-set version fights the one it derives.

What actually happens when you run `bin/release prepare` from mcritchie-studio:

1. It derives the bump from the candidate's MEMBERSHIP — any member risk-tagged
   `breaking` → **major**, else any member with `kind: feature` → **minor**, else
   **patch** — against the last published version.
2. It commits `lib/studio/version.rb` **with its `Gemfile.lock`**, onto
   **`origin/release`** (not `accepted`), before anything is published.
3. It publishes to RubyGems and tags, producer-first, then bumps each consumer's
   lock onto that consumer's `release`.

It narrates the decision, e.g.:

```text
→   gem studio-engine: allocated 0.46.0 — 0.45.0 + minor (minor from
    engine-onboarding-modal-primitive) → 0.46.0; committed with its lockfile
    onto origin/release
```

The allocation can also REFUSE (it names what to fix) or decline to allocate at
all (nothing to publish). Both are reported; neither wants a hand-edit.

**Why `Gemfile.lock` must ride with the version** — this rule is unchanged and
still bites. The engine bundles itself as a path gem, so `Gemfile.lock` pins its
own version (`PATH remote: .` → `studio-engine (x.y.z)`). CI runs bundler frozen
(`bundler-cache: true`), so a version that moved without its lockfile dies with
*"the gemspecs for path gems changed, but the lockfile can't be updated because
frozen mode is set"* — before a single test runs. It is invisible locally,
because any `bundle install` or test run silently regenerates the lockfile in
your working tree while the commit stays broken. Prepare handles this for you;
the rule matters if you ever touch the version by hand under the fallback below.

**Expect a publish→CI race.** A consumer lane can go red in *Set up Ruby* with
`bundle` exit 7 (*"Your bundle is locked to studio-engine (x.y.z) ... found in
that source"*) for a few minutes after a publish, because RubyGems has not
propagated yet. That is not a regression and not a reason to eject a task —
re-run the failed jobs once the version resolves.

### Publishing by hand (fallback)

`bin/release prepare` automates this. Run it manually only when the conductor
path is unavailable, and only after explicit approval:

```bash
bin/release-check --build
gem push /tmp/studio-engine-release-check/studio-engine-<version>.gem
git tag v<version>
git push origin main --tags
```

### Correcting a released entry — annotate, don't rewrite

A published `CHANGELOG.md` entry is copy-from material: people paste commands out
of it, so a wrong one has to be corrected rather than left standing on grounds of
historical purity. Correct it **in place as an annotated erratum** — keep the
original text struck through, name what was wrong, and point at the version that
fixed it:

```markdown
(~~`bin/rails studio:install:migrations`~~ — **erratum, 0.30.1:** that command
does not exist; the correct task is `studio_engine:install:migrations`).
```

Never silently replace the original wording: a reader who copied the old command
needs to recognize what they took. The fix itself still gets its own entry under
the new version.

## Consumer Adoption

**`bin/release prepare` already bumps each consumer's lock** onto that consumer's
`release` branch as part of the sweep. This section is for adopting a published
version OUT OF BAND — a single app taking a new engine ahead of a release, which
is what an adoption task does.

There are **three** consumers today:

```bash
cd /Users/alex/projects/mcritchie-studio    && bundle update --conservative studio-engine
cd /Users/alex/projects/turf-monster        && bundle update --conservative studio-engine
cd /Users/alex/projects/mcritchie-industries && bundle update --conservative studio-engine
```

`--conservative` on purpose: a bare `bundle update studio-engine` is free to
float the rest of the dependency graph, which turns a one-line engine bump into
an unreviewable lockfile diff.

Verify each `Gemfile.lock` resolves the version you expect — **the lockfile, not
the Gemfile pin** (a two-segment `~>` admits far more than it appears to). If the
adoption RAISES the app's real floor, say why in the pin comment; that comment is
where this ecosystem records which primitive made the floor move.

**If the engine release ships migrations, installing the gem is not enough:**

```bash
bin/rails studio_engine:install:migrations && bin/rails db:migrate
```

Engine migrations are install-COPIED, not auto-run, so an app can carry a gem
whose tables it never created. mcritchie-industries has a contract test for
exactly this (`test/lib/engine_pin_contract_test.rb`) — it fails when the
resolved engine ships a migration the app never ran.

Then run the consumer smoke checks:

```bash
# McRitchie Studio
cd /Users/alex/projects/mcritchie-studio
bin/rails -T ses
MAIL_TRANSPORT=ses SES_SMTP_USERNAME=user SES_SMTP_PASSWORD=pass SES_REGION=us-east-2 \
  bin/rails runner 'puts({delivery: ActionMailer::Base.delivery_method, host: ActionMailer::Base.smtp_settings[:address]}.inspect)'

# Turf Monster
cd /Users/alex/projects/turf-monster
bin/rails -T ses
SOLANA_SKIP_NETWORK_CHECK=true MAIL_TRANSPORT=ses SES_SMTP_USERNAME=user SES_SMTP_PASSWORD=pass SES_REGION=us-east-2 \
  bin/rails runner 'puts({delivery: ActionMailer::Base.delivery_method, host: ActionMailer::Base.smtp_settings[:address]}.inspect)'
```

Finally, prove the local apps still boot:

- McRitchie Studio: `http://localhost:3000/`
- Turf Monster: `http://localhost:3100/`
- McRitchie Industries: `http://localhost:3500/`

## Temporary Fallback Cleanup

Consumer-side fallbacks from the SES/Resend transport migration. **Verified
2026-08-19** rather than assumed:

- `lib/tasks/ses.rake` — **already removed** from mcritchie-studio and
  turf-monster. `bin/rails -T ses` now shows the engine-provided tasks.
- `config/initializers/studio_mail_transport.rb` — **still present** in both
  apps. Read it before deleting: only the local COMPATIBILITY BRANCH is the
  cleanup candidate, and each app may have grown its own configuration around it
  since.
- App-level `gem "resend"` rollback dependencies — remove once the engine
  dependency covers the app and no local transport fallback code remains.

Keep `RESEND_API_KEY` available as an operational rollback.
