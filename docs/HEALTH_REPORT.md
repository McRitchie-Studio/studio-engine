# Daily Health Report

`Studio::HealthReportJob` emails one operator a short report on the app's last
day: new signups, errors from `ErrorLog` grouped by class and message (with
counts and first and last seen), contact-form submissions if the app names
them, and a one-line all-clear on a quiet day. The day runs 07:00 to 07:00 in
the app's zone, so a daylight-saving change makes it 23 or 25 hours rather
than dropping or repeating an hour.

It is **off by default**. Nothing sends until an app does both of these:

1. **Schedules the job** at `Studio.health_report_hour` in
   `Studio.health_report_zone` (07:00 America/Denver unless changed).
2. **Names a recipient**, in `config.health_report_to` or the
   `STUDIO_HEALTH_REPORT_TO` env var.

With no recipient the job returns before it reads a row. QA apps
(`QA_ENV=true`) never send. A failure is an `ErrorLog` row, and so a line in the
next report, never a retry.

Most apps need neither. The McRitchie Studio hub pulls the same report as JSON
from every app at 07:00 America/Denver and posts it to Discord, so an app with no
production worker is covered by setting one token; see
[The hub endpoint](#the-hub-endpoint).

## Turn it on

### 1. Schedule it

Solid Queue, `config/recurring.yml`:

```yaml
production:
  studio_health_report:
    class: Studio::HealthReportJob
    schedule: "0 7 * * * America/Denver"
```

sidekiq-cron, `config/schedule.yml`. `active_job: true` is required on Sidekiq 7;
without it the tick raises at enqueue and nothing runs:

```yaml
studio_health_report:
  cron: "0 7 * * * America/Denver"
  class: "Studio::HealthReportJob"
  queue: default
  active_job: true
```

A run that lands late, or a manual `Studio::HealthReportJob.perform_now`,
reports the same 07:00-to-07:00 day an on-time run would.

### 2. Name the recipient

Either set the env var on the app:

```bash
STUDIO_HEALTH_REPORT_TO="ops@example.com"         # comma-separated for several
```

or set it in `config/initializers/studio.rb`, which wins over the env var:

```ruby
Studio.configure do |config|
  config.health_report_to = "ops@example.com"     # String, Array, or a callable
end
```

## Fit it to the app

All settings live in `config/initializers/studio.rb`; each is optional.

| Setting | Default | What it does |
|---|---|---|
| `health_report_to` | `nil` (then `ENV["STUDIO_HEALTH_REPORT_TO"]`) | Who gets it. Blank everywhere means no email. |
| `health_report_zone` | `"America/Denver"` | The wall clock the day is cut on. Schedule the job in the same zone. |
| `health_report_hour` | `7` | The hour that opens and closes the day. |
| `health_report_signups` | the host's `User`, by `created_at` | A callable taking the window; `nil` omits the section. |
| `health_report_contacts` | `nil` (no section) | A callable taking the window. |

A source callable receives the window (a `Range` of times, end excluded) and
returns a relation, an Array, or an Integer count. A relation or Array lists up
to 10 rows by name and counts all of them; an Integer prints the count only. A
row's name is its `health_report_label` if it has one, else its
`display_name`/`name` and `email`.

```ruby
Studio.configure do |config|
  # An app with a contact form names its model.
  config.health_report_contacts = ->(window) { ContactSubmission.where(created_at: window).order(created_at: :desc) }

  # An app whose accounts are not `User` points signups at its own model.
  config.health_report_signups = ->(window) { Account.where(created_at: window).order(created_at: :desc) }

  # Count only, no names.
  config.health_report_signups = ->(window) { User.where(created_at: window).count }
end
```

A source that raises does not stop the report: its section reads "could not be
read", the error is logged, and the other sections send.

## The hub endpoint

`GET /_studio/health_report` answers the report as JSON. The McRitchie Studio
hub runs one 07:00 America/Denver job that pulls it from every app and posts to
Discord; that central pull, not a per-app schedule, is how the platform reads
its apps, since most satellites run no worker in production.

`Studio.routes` draws it in every environment, production included. It is
**inert until the app names a token**:

```bash
STUDIO_HEALTH_TOKEN="<a long random secret>"   # the hub holds the same value for this app
```

or `config.health_report_token = "..."` in `config/initializers/studio.rb`,
which wins over the env var. Generate one with
`ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`, file it in 1Password
beside the app's other secrets, and give the hub the same value.

| Request | Answer |
|---|---|
| No token configured | `404`, empty body: the endpoint does not admit it exists |
| Missing or wrong `Authorization: Bearer <token>` | `401` `{"error":"unauthorized"}` |
| `?ending=` not ISO 8601 | `400` |
| The right token | `200`, the report below, `Cache-Control: no-store` |

`?ending=<ISO 8601 time>` reports the day that ends there (the same
`Studio::HealthReport.window_ending` the job uses); without it, the day the job
would report now. URL-encode it: a raw `+` in an offset arrives as a space and
answers 400 (`Z` or a `-` offset needs no encoding). The token is compared in constant time. The controller runs
on `ActionController::API`, so the host's `before_action`s (sign-in, geo,
`allow_browser`) never run: no session, no cookie, no redirect.

```bash
curl -s -H "Authorization: Bearer $STUDIO_HEALTH_TOKEN" \
  "https://app.example.com/_studio/health_report?ending=2026-10-13T07:00:00-06:00"
```

```json
{
  "schema": 1,
  "app": "Turf Monster",
  "engine_version": "0.109.0",
  "window": { "begin": "2026-10-12T07:00:00-06:00", "end": "2026-10-13T07:00:00-06:00",
              "label": "Oct 12, 7:00 AM to Oct 13, 7:00 AM MDT" },
  "quiet": false,
  "sections": [
    { "key": "signups", "title": "Signups", "count": 2, "failure": null },
    { "key": "errors", "title": "Errors", "count": 3, "failure": null }
  ],
  "error_kinds": 1,
  "error_groups": [
    { "error_class": "KeyError", "message": "key not found: :x", "count": 3,
      "first_seen": "2026-10-12T20:00:00Z", "last_seen": "2026-10-13T01:00:00Z" }
  ]
}
```

**Counts only, by construction.** A section carries its key (`signups`,
`errors`, `contacts`, each present only when the app has that section), its
title, its count, and its `failure` (the error class when its source raised,
else `null`). The names and emails the email lists never enter the JSON, so no
signup or contact detail leaves the app. `error_groups` holds at most 15
distinct errors, messages already truncated to 300 characters. `schema` changes
only on a breaking change to these keys.

## Preview it

In a desk with local email capture, run the job with a recipient and open the
captured mail at `/_studio/local_emails`:

```bash
STUDIO_HEALTH_REPORT_TO=you@example.com bin/rails runner 'Studio::HealthReportJob.perform_now'
```
