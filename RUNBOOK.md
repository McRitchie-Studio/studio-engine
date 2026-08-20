# Runbook -- Studio Engine

Troubleshooting guide for autonomous agents. Format: problem, diagnosis, fix.

## Consuming App Won't Load Engine

**`Bundler::GemNotFound` for studio**
- Diagnosis: Gemfile expects `studio-engine` from RubyGems but Bundler cannot resolve it. Network, RubyGems, or lockfile issue.
- Fix: Check the consuming app's Gemfile declares `gem "studio-engine"` (each app pins its own floor — read the pin there rather than assuming a number). Run `bundle install --verbose`. If a just-published release is missing, confirm RubyGems shows it before retrying.

**Engine classes not available (NameError)**
- Diagnosis: `ErrorLog`, `Sluggable`, or `Studio::ErrorHandling` not found. Engine not loaded.
- Fix: Verify the consuming app's Gemfile declares `gem "studio-engine"` (each app pins its own floor). Run `bundle install`. Check `config/initializers/studio.rb` exists with a `Studio.configure` block. Verify `Studio.routes(self)` is in `config/routes.rb`.

**`Studio` constant undefined at boot**
- Diagnosis: Initializer runs before engine loads.
- Fix: The engine's `lib/studio.rb` defines the module. Ensure `require "studio"` is not called manually -- Bundler handles it. Check load order: engine gems load before app initializers.

## View Overrides Not Working

**App view not taking precedence over engine view**
- Diagnosis: Rails loads app views before engine views. If the app view has a different path, it won't override.
- Fix: The override path must match exactly. Engine view at `studio/app/views/sessions/new.html.erb` is overridden by `myapp/app/views/sessions/new.html.erb`. Check for typos in directory names. Common overrides: `sessions/new`, `registrations/new`, `sessions/_sso_continue`, `components/_admin_dropdown`.

**Cached view showing old engine version**
- Diagnosis: After `bundle update --conservative studio-engine`, Rails may serve a cached view from the previous engine version.
- Fix: Restart the Rails server. In development: `bin/rails tmp:cache:clear`. On Heroku, deploys clear the cache automatically.

**Partial not found after engine update**
- Diagnosis: Engine partial was renamed or moved. `ActionView::MissingTemplate` error.
- Fix: Check the engine's current view paths: `ls /Users/alex/projects/studio-engine/app/views/`. If the app has a local override of a removed partial, delete the app's version.

## Theme Not Updating

**Colors stale after ThemeSetting change**
- Diagnosis: `studio_theme_css_tag` reads from Rails cache. Cache key: `studio/theme/<app_name>`. TTL is 1 hour.
- Fix: Clear cache for the specific app. In the consuming app's console: `Rails.cache.delete("studio/theme/#{Studio.app_name}")`. Or visit `/admin/theme` and click "Regenerate Cache".

**DB values not overriding config defaults**
- Diagnosis: `ThemeSetting` has nullable columns. A nil column falls back to `Studio.theme_config` defaults.
- Fix: Check the DB record: `ThemeSetting.current.attributes`. Verify the column name matches. DB uses `accent1`/`accent2` for the `success`/`accent` roles -- mapped via `ThemeSetting.db_column_for`. Setting a column to nil intentionally resets to config default.

**CSS vars not generating primary palette**
- Diagnosis: `--color-primary-{50..900}` or `-rgb` variants missing from rendered `<style>` tag.
- Fix: Check `Studio::ThemeResolver` receives a valid hex for `primary`. In console: `Studio::ThemeResolver.new(Studio.theme_config).to_css` -- inspect the output. If the primary color is nil or empty, palette generation is skipped.

**Theme page (admin/theme) returns 403/redirect**
- Diagnosis: `require_admin_for_theme` before_action rejects non-admin users.
- Fix: Verify the logged-in user has `role == "admin"`. Check `current_user.admin?` in console.

## SSO Session Issues

**Shared cookie not working across subdomains**
- Diagnosis: SSO relies on `_studio_session` cookie spanning `*.mcritchie.studio`. If domain config is wrong, apps can't read each other's session data.
- Fix: Both apps must have identical `config/initializers/session_store.rb`: `key: "_studio_session", domain: (Rails.env.production? ? ".mcritchie.studio" : :all)`. Both must share the same `SECRET_KEY_BASE` env var.

**`sso_user_available?` returns false**
- Diagnosis: Three conditions required: (1) not logged in to current app, (2) `sso_email` present in session, (3) `sso_source` is a different app.
- Fix: Log into the hub app (McRitchie Studio) first -- this populates `sso_*` fields. Check that `Studio.session_key` is unique per app (`:studio_user_id` vs `:turf_user_id`). If both apps use the same key, SSO detection breaks.

**Session key conflicts**
- Diagnosis: Both apps use the same `config.session_key`. Logging into one app overwrites the other's session.
- Fix: Each app MUST use a unique symbol: McRitchie Studio = `:studio_user_id`, Turf Monster = `:turf_user_id`. Set in `config/initializers/studio.rb`.

## Error Log Search Performance

**Slow ILIKE search on error_logs**
- Diagnosis: `ErrorLogsController#index` uses ILIKE with wildcards for full-text search. Slow on large tables.
- Fix: Check index: `\d error_logs` in psql. If no trigram index exists, add one: `CREATE INDEX idx_error_logs_message_trgm ON error_logs USING gin (message gin_trgm_ops);` (requires `pg_trgm` extension). For now, the table is small enough that sequential scan is acceptable.

## Updating Engine and Pushing to Consumers

**Standard update flow**
1. Make changes in `/Users/alex/projects/studio-engine/`
2. Run `bin/release-check`
3. Open the PR into `accepted`. **Do not bump `lib/studio/version.rb`** — the
   release owns the version and `bin/dor-check` refuses a PR that edits it.
   `CHANGELOG.md` is not gated. See `docs/RELEASE.md` for who sets the number.

Steps 4-7 below are the **manual** consumer-adoption path. On the normal
release, `bin/release prepare` does all of it — it publishes the gem, tags it,
and commits each consumer's `Gemfile.lock` bump onto that consumer's `release`
branch. Reach for these only outside the conductor path:

4. In McRitchie Studio: `cd /Users/alex/projects/mcritchie-studio && bundle update --conservative studio-engine`
5. In Turf Monster: `cd /Users/alex/projects/turf-monster && bundle update --conservative studio-engine`
6. In McRitchie Industries: `cd /Users/alex/projects/mcritchie-industries && bundle update --conservative studio-engine`
7. Test all three apps and prove the local URLs still boot
8. Deploy consumers after app-level verification passes

`--conservative` on purpose: a bare `bundle update studio-engine` is free to
float the rest of the dependency graph, turning a one-line engine bump into an
unreviewable lockfile diff. Verify each `Gemfile.lock` resolves what you expect —
the lockfile, not the Gemfile pin, since a two-segment `~>` admits far more than
it appears to.

**Consumer locked to old version**
- Diagnosis: `bundle update --conservative studio-engine` does not pull the latest published version.
- Fix: Confirm RubyGems has the target version. Check `Gemfile.lock` for the resolved version, then retry `bundle update --conservative studio-engine`. If the app has a local Bundler override, clear it with `bundle config unset --local local.studio`.

**Engine test approach**
- Diagnosis: Some engine behavior is pure Ruby and some only proves out inside a consuming Rails app.
- Fix: Run `bin/release-check` for engine unit coverage. Then bundle the released version into consumers and run app-specific smoke checks for controllers, routes, mailers, views, and local URLs.
