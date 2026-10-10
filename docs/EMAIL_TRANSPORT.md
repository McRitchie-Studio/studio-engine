# Email Transport

`Studio::MailTransport` is the shared transactional email selector for Studio
apps. It keeps McRitchie Studio, Turf Monster, and future apps on one
ActionMailer transport contract.

Resend is the only provider. The SES transport was removed when AWS was
retired on 2026-10-10 (no IAM users or SES identities remain), so
`MAIL_TRANSPORT=ses` no longer selects anything.

Cross-app sender inventory, local inbox proof rules, and operating criteria live in
`mcritchie-studio/docs/agents/modules/email-operations.md`.

`Studio::Email.deliver(...)` is the shared delivery entry point. It records a
durable outbox row before enqueueing delivery when the host app has either:

- an existing app-level `EmailDelivery` model, or
- the engine-provided `Studio::EmailDelivery` table installed.

If no durable adapter is available, it falls back to normal ActionMailer
`deliver_later` so apps can adopt the API before installing the outbox table.

## App Initializer

```ruby
# config/initializers/studio_mail_transport.rb
Studio::MailTransport.configure!
```

The app still owns `Studio.mailer_from` in `config/initializers/studio.rb`.
Use the sender helper, which answers `RESEND_MAILER_FROM`, then `resend_from:`,
then `Studio.resend_mailer_from`:

```ruby
Studio.configure do |config|
  config.mailer_from = Studio.mailer_from_for_transport(
    resend_from: "My App <team@example.com>" # optional; must be on a Resend-verified domain
  )
end
```

`Studio.marketing_from_for_transport` answers `RESEND_MARKETING_FROM`, then
`RESEND_MAILER_FROM`, then `resend_from:`, then `Studio.resend_mailer_from`.
Both still ACCEPT a `ses_from:` keyword so older initializers keep booting, and
both IGNORE it; drop it when you next touch the initializer. `MAILER_FROM` and
`MARKETING_MAILER_FROM` are no longer read by these helpers. A sender must
belong to a domain verified in Resend.

## Selection Rules

| Env | Delivery method | Notes |
|-----|-----------------|-------|
| `RESEND_API_KEY` | `:resend` | The production transport. |
| `MAIL_TRANSPORT=ses` | as if unset | Logs a "no longer supported" warning, then follows the rows above and below. |
| `MAIL_TRANSPORT` set to anything but `resend` or `ses` | as if unset | Logs an "unknown" warning. |
| no transport env | existing default | Useful in dev/test shells that do not send real mail. |

Tests are intentionally skipped so app test suites can keep `:test` delivery.

## Required Env

```env
RESEND_API_KEY=...
RESEND_MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"
RESEND_MARKETING_FROM="Alex from My App <alex@example.com>"   # optional
```

`MAIL_TRANSPORT` may stay unset, or be `resend`. The `SES_*` variables and the
engine's `ses:check` / `ses:verify_domain` rake tasks are gone.

## Provider Smoke Test

Use the shared smoke task when the question is "can this app send one real
email through its current provider?"

```bash
bin/rails "email:smoke[to@example.com]"
```

`EMAIL_SMOKE_TO=to@example.com bin/rails email:smoke` is equivalent when a shell
or process manager makes bracket arguments awkward.

The task sends one direct ActionMailer message, bypassing app-specific mailers,
outbox workers, and auth flows. It prints the app name, recipient, sender,
transport (`resend`, `capture`, or the ActionMailer delivery method),
`perform_deliveries`, external-send status, and message id.

By default it refuses to proceed when mail would be captured, written to file,
delivered through the test adapter, or skipped by `perform_deliveries=false`.
Set `EMAIL_SMOKE_ALLOW_NON_EXTERNAL=1` only when intentionally proving
capture/test mode; do not use that as provider proof.

## Durable Delivery

New apps should install the engine migrations before relying on durable delivery:

```bash
bin/rails studio_engine:install:migrations
bin/rails db:migrate
```

Scope it to `studio_engine:` rather than `railties:` — the latter copies the
migrations of **every** railtie in the bundle, which is far more than you asked
for. Install the full engine set and re-run after each upgrade; the details, and
why you should not delete copies you think you don't need, are in
[`NEW_APP_SETUP.md`](NEW_APP_SETUP.md) § 5.

The table is `studio_email_deliveries`; the model is `Studio::EmailDelivery`.
Use the facade from app code:

```ruby
Studio::Email.deliver(UserMailer, :magic_link, email, token, to: email, user: user)
```

`Studio::EmailDelivery.resend_unsent!` re-enqueues any unsent rows after a
provider or worker outage. Apps with an older top-level `EmailDelivery` model can
keep it during migration; `Studio::Email.deliver` will use that adapter first.
