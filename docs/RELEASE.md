# Studio Engine Release Runbook

This repo publishes the shared `studio-engine` gem. Consumer apps pull released
versions from RubyGems with `gem "studio-engine", "~> 0.6"`.

Do not publish, push tags, deploy consumers, or rotate credentials from an
agent session without explicit approval.

## Current Release

The current published release used by local consumers is `v0.6.0`:

- `tailwindcss-rails ~> 4.5` is the shared Tailwind CSS v4 build-chain
  dependency for Studio apps.
- `Studio::AdminModels`, shared operator banners, shared Dev Mode controls,
  and shared impersonation banner primitives are available for consumers on
  `0.5.10`.
- `Studio::MailTransport` selects SES SMTP or Resend through ActionMailer.
- Shared `ses:check` and `ses:verify_domain` Rake tasks.
- `resend` is now a runtime dependency of the engine so consumers do not need
  to carry it directly after they bundle the release.
- `Studio::Email.deliver`, local email capture, scanner-safe magic links, and
  wallet-address adapters are available for consumers on `0.5.6`.
- `StudioEmailDeliveryHelper#email_delivery_banner_status` provides shared
  non-production mail-state banner text for consumers on `0.5.8`.
- `email:smoke[to@example.com]` sends a direct provider smoke-test message and
  refuses swallowed/captured delivery modes by default.

If additional engine changes are added before publish, review whether this
should remain a patch release or move to the next minor.

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

The bump is derived from the candidate's membership: any member risk-tagged
`breaking` → **major**, else any member with `kind: feature` → **minor**, else
**patch**; `next = last published v* tag + that bump`. `Release::GemVersion` in
mcritchie-studio encodes those rules, but **nothing calls it yet** —
`bin/release prepare` does NOT allocate the version. Until it does, you set the
number by hand:

1. Compute `next` from the table above.
2. Commit it **directly onto `accepted`** — no rung here is branch-protected,
   and the batch promote PR carries it to `release` without a `dor-check`:

```bash
cd /Users/alex/projects/studio-engine
git checkout accepted && git pull
# edit lib/studio/version.rb to <next>
bundle install          # REQUIRED — see below
git add lib/studio/version.rb Gemfile.lock
git commit -m "Release <next>" && git push origin accepted
```

   **`Gemfile.lock` must ride in the same commit.** The engine bundles itself as
   a path gem, so `Gemfile.lock` pins its own version (`PATH remote: .` →
   `studio-engine (x.y.z)`). CI runs bundler frozen (`bundler-cache: true`), so a
   version that moved without its lockfile dies with *"the gemspecs for path gems
   changed, but the lockfile can't be updated because frozen mode is set"* —
   before a single test runs. This is invisible locally, because any
   `bundle install` or test run silently regenerates the lockfile in your working
   tree while the commit stays broken.

3. Run `bin/release prepare` from mcritchie-studio. It publishes the gem to
   RubyGems and tags `v<version>` as its producer-first step, then bumps each
   consumer's lock. Skip step 2 and prepare's **stranded-work guard** aborts the
   sweep for *every* repo.

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

Adopt the engine release in consumers after RubyGems shows the new version:

```bash
cd /Users/alex/projects/mcritchie-studio
bundle update studio-engine

cd /Users/alex/projects/turf-monster
bundle update studio-engine
```

Verify each `Gemfile.lock` resolves the published version. For the shared mail
transport, local email capture, and non-production banner path, consumer apps
should resolve the current `studio-engine 0.6.0` release.

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

## Temporary Fallback Cleanup

Only remove the consumer fallbacks after both apps are bundled with the engine
release that contains `Studio::MailTransport`.

Cleanup candidates:

- Remove the local compatibility branch from each
  `config/initializers/studio_mail_transport.rb`.
- Remove each app's fallback `lib/tasks/ses.rake` once `bin/rails -T ses` shows
  the engine-provided tasks.
- Remove direct app-level `gem "resend"` rollback dependencies once the engine
  dependency is present and the apps no longer need local transport fallback
  code.

Keep `RESEND_API_KEY` available as an operational rollback until SES has proven
stable in production.
