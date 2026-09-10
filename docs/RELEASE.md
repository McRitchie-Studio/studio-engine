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
  under `Unreleased` as it goes (the changelog is not gated by `dor-check`), and
  which `bin/release prepare` rolls into the version heading when it allocates
  the version (see **Rolling `Unreleased` into a version** below).
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
   Write under `## Unreleased` and nowhere else, and never write a version
   heading: `bin/release prepare` writes it when the release allocates your
   version (see **Rolling `Unreleased` into a version** below).
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
2. It commits `lib/studio/version.rb` **with its `Gemfile.lock` and a rolled
   `CHANGELOG.md`** (one commit, `Release <version>`) onto **`origin/release`**
   (not `accepted`), before anything is published.
3. It publishes to RubyGems and tags, producer-first, then bumps each consumer's
   lock onto that consumer's `release`.

It narrates the decision, e.g.:

```text
→   gem studio-engine: allocated 0.46.0 — 0.45.0 + minor (minor from
    engine-onboarding-modal-primitive) → 0.46.0; committed with its lockfile
    onto origin/release
```

Each swept gem gets one of three outcomes, named for `Release::GemVersion`'s own
decisions:

- **ALLOCATE**: a version is written AND `## Unreleased` is rolled, in the same
  commit.
- **SKIP**: nothing allocated, nothing rolled; the run prints
  `gem studio-engine: <reason> — nothing allocated`.
- **REFUSE**: the decide phase aborts; nothing written, nothing published. The
  message names what to fix.

None of them wants a hand-edit of `lib/studio/version.rb`. A SKIP or a REFUSE
can want a hand-edit of `CHANGELOG.md`; the next section says when.

#### Rolling `Unreleased` into a version

**`bin/release prepare` does this for you, on ALLOCATE and only on ALLOCATE**
(mcritchie-studio#1344). In the commit that sets `lib/studio/version.rb` and
`Gemfile.lock`, it keeps `## Unreleased` as the first `## ` heading, now empty,
writes `## <allocated version> — <date>` directly beneath it in this file's own
form (`## 0.74.3 — 2026-09-08`), and moves everything that sat under
`## Unreleased` under the new heading. The heading is the only new line; the roll
writes no prose. The commit lands on `origin/release` before `gem push`, so the
published gem and its `v*` tag both carry a changelog that already names the
release:

```text
→   gem studio-engine: rolled '## Unreleased' into '## 0.75.0 — 2026-09-11' (30 line(s))
```

**When it REFUSES because of this file.** In the decide phase prepare reads
`CHANGELOG.md` at `origin/release` for every gem it is about to allocate, and
aborts the whole sweep — nothing written, nothing published — when the roll
would lie or the file cannot be read:

| The refusal names | Fix it by |
|---|---|
| a **BACKLOG**: the newest version heading is more than two minor versions (or a whole major) behind the last published version, *while `## Unreleased` holds entries* | attributing those entries to the versions that shipped them (**By hand**, below) |
| a newest heading **AHEAD** of the last published version | deleting that heading, so its entries sit under `## Unreleased` again |
| an **unterminated fenced code block** (it names the opening line) | closing the fence |
| no `## Unreleased`, more than one, or one that is not the first `## ` heading | restoring exactly one, first |
| a `## ` heading that is neither a version nor `## Unreleased` (it names the line) | rewriting it in this file's form |
| no `## ` heading at all, or no version heading while a version is published | restoring the file from git |

"Last published" is the higher of the last `v*` tag reachable from
`origin/release` and the highest version live on RubyGems. A `## ` line inside a
**closed** fence is content, not a heading, so quoting a heading in an entry is
safe. Land the fix as a docs PR on `accepted`, then re-run `bin/release prepare`:
it resumes, and its `accepted → release` promote carries the fix.

**When it SKIPS, nothing rolls.** The changelog guard and the roll both run only
for a gem prepare ALLOCATES, so a SKIP neither rolls this file nor checks it.
Prepare skips when there are no commits past the last `v*` tag, when nothing has
ever been published, and when **`lib/studio/version.rb` at `origin/release`
already leads the last `v*` tag** ("allocated already"). This file feels the
last case, and three things reach it:

1. **A version set by hand**: committed straight onto `accepted`, as a failed
   `gem push` suggests, or bumped any other way outside prepare. It publishes
   with its entries still under `## Unreleased`, and the next ALLOCATE files
   them under the NEXT version (or, past the drift tolerance, REFUSES them as a
   BACKLOG). Roll by hand in the SAME commit that sets the version.
2. **A re-run after an abort between the version commit and its tag**, such as
   a red gem CI gate. The roll already rode the `Release <version>` commit. Work
   that reaches `origin/release` after it (the re-run promotes `accepted` again)
   ships in that same version, but prepare rolls none of its entries; git's merge
   decides where they land (see **`accepted` lags `release`**, below).
3. **The window inside one sweep** between the version commit and its tag: 13
   to 24 minutes across the eight gem publishes of 2026-09-09/10. Nothing to
   do; the roll is already in the commit.

That window is **not** the state between sweeps. Measured at `origin/release` on
2026-09-10, studio-engine sat at `0.74.8` with tag `v0.74.8`, and solana-studio
at `0.10.0` with `v0.10.0`. An earlier reading of "0.74.7 against `v0.74.6`"
came from inside case 3: the 0.74.7 version commit is stamped 22:09:28 MDT and
`v0.74.7` was tagged at 22:29:32.

Prepare also rolls nothing when a gem has no `CHANGELOG.md` (it says so and
allocates anyway), and **Publishing by hand (fallback)** below bypasses prepare,
so it rolls nothing either.

**An entry-less release still gets its heading.** When `## Unreleased` is empty
at an ALLOCATE, prepare writes the version heading anyway and moves nothing
("no entries — the heading records the release"). An empty version section means
"this version shipped and recorded no entry". Do not fill it with placeholder
prose, and do not skip the heading: the newest heading must name the newest
published version. Skipping it is how drift builds: three entry-less minors in a
row reach a drift of three and redden `test/docs/changelog_structure_test.rb`
with a remedy that has nothing to roll. A hand roll follows the same rule:
rename even when the bucket is empty. Older releases that recorded nothing and
carry no heading stay as reconstructed; both guards measure drift from the
NEWEST heading only, so a gap in old numbering cannot redden anything.

**`accepted` lags `release`.** The `Release <version>` commit lands on
`origin/release` and reaches `accepted` only through a later merge (0.74.7
arrived in `82743f5`). On 2026-09-10 `release` carried 0.74.8 while `accepted`
still carried 0.74.7. Two rules follow.

- **Never land a heading before its version.** Prepare cannot: the heading and
  the version ride one commit. A hand roll can, and it trips two guards: this
  repo's `test/docs/changelog_structure_test.rb` ("AHEAD of `Studio::VERSION`")
  on the branch where it lands, and prepare's AHEAD refusal on the sweep that
  would allocate it. Before you land a heading for version N, confirm the
  branch already names N:

  ```bash
  git fetch origin && git show origin/accepted:lib/studio/version.rb
  ```

- **Check every merge that crosses a roll.** Until the rolled file reaches
  `accepted`, entries written there sit in the old bucket, and git's three-way
  merge of the two is not safe. Measured with the real roll on this file: a
  bullet added inside an existing `###` subsection merges CLEAN and lands under
  the newly rolled version heading, a version that shipped without it; a new
  subsection at the top of the bucket CONFLICTS. After such a merge, make sure
  the newest version heading holds only what that version shipped, and move
  anything else back under `## Unreleased`.

**By hand, when a case above sends you here.** On a docs PR into `accepted`, or
in the same commit as a hand-set version:

1. Attribute each entry to the version that shipped it: `git log -S` finds its
   commit, and the earliest `v*` tag containing that commit is its version. Use
   only versions already published and already named on the target branch.
2. Give each such version its heading beneath `## Unreleased`, in the file's own
   form (`## <version> — <YYYY-MM-DD>`), and move its entries under it. Write the
   heading even when it has no entries.
3. Leave entries for unshipped work under `## Unreleased`; prepare rolls them at
   the next ALLOCATE.

**History.** Before mcritchie-studio#1344 prepare committed the version,
published and tagged without touching this file, and nothing failed when the
roll was skipped. Between 0.39.0 and 0.74.x, `## Unreleased` grew to 2,382 lines
holding thirty-five minor versions of shipped entries, so the heading called the
gem's whole history "pending". #314 attributed that backlog and added
`test/docs/changelog_structure_test.rb`, which fails when `Studio::VERSION` runs
more than two minor versions ahead of the newest version heading (patch releases
do not move that number). The two guards share that tolerance and differ on
purpose: prepare measures the last PUBLISHED version and refuses only when the
bucket holds entries, while this repo's test measures `Studio::VERSION` on the
branch, unconditionally, and is the stricter of the two.

**Why `Gemfile.lock` must ride with the version** — this rule is unchanged and
still bites. The engine bundles itself as a path gem, so `Gemfile.lock` pins its
own version (`PATH remote: .` → `studio-engine (x.y.z)`). CI runs bundler frozen
(`bundler-cache: true`), so a version that moved without its lockfile dies with
*"the gemspecs for path gems changed, but the lockfile can't be updated because
frozen mode is set"* — before a single test runs. It is invisible locally,
because any `bundle install` or test run silently regenerates the lockfile in
your working tree while the commit stays broken. Prepare handles this for you;
the rule matters if you ever touch the version by hand under the fallback below,
and a version set by hand needs its changelog rolled by hand in the same commit.

**Expect a publish→CI race.** A consumer lane can go red in *Set up Ruby* with
`bundle` exit 7 (*"Your bundle is locked to studio-engine (x.y.z) ... found in
that source"*) for a few minutes after a publish, because RubyGems has not
propagated yet. That is not a regression and not a reason to eject a task —
re-run the failed jobs once the version resolves.

### Publishing by hand (fallback)

`bin/release prepare` automates this. Run it manually only when the conductor
path is unavailable, and only after explicit approval. This path skips prepare,
so nothing rolls `CHANGELOG.md`: roll it by hand (**Rolling `Unreleased` into a
version**, above) in the commit that sets the version.

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
`## Unreleased`, which rolls into the new version.

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
