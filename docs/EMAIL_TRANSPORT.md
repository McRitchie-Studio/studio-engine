# Email Transport

`Studio::MailTransport` is the shared transactional email selector for Studio
apps. It keeps McRitchie Studio, Turf Monster, and future apps on one
ActionMailer transport contract.

Cross-app sender inventory, SES rollout policy, local inbox proof rules, and
rollback/decommission criteria live in
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
Use the provider-aware helper so SES uses the app's verified domain while
Resend fallback can use a single shared verified sender:

```ruby
Studio.configure do |config|
  config.mailer_from = Studio.mailer_from_for_transport(
    ses_from: "My App <team@example.com>"
  )
end
```

`MAILER_FROM` must belong to a domain verified in SES. `RESEND_MAILER_FROM`
must belong to the shared domain verified in Resend.

## Selection Rules

| Env | Delivery method | Notes |
|-----|-----------------|-------|
| `MAIL_TRANSPORT=ses` plus `SES_SMTP_USERNAME` and `SES_SMTP_PASSWORD` | `:smtp` | Target transport. Uses AWS SES SMTP. |
| `MAIL_TRANSPORT=ses` without SES SMTP credentials | fallback | Logs a warning and continues to fallback. |
| `RESEND_API_KEY` with SES inactive | `:resend` | Rollback transport. |
| no transport env | existing default | Useful in dev/test shells that do not send real mail. |

Tests are intentionally skipped so app test suites can keep `:test` delivery.

## Required Env

```env
MAIL_TRANSPORT=ses
SES_REGION=us-east-2
SES_SMTP_USERNAME=...
SES_SMTP_PASSWORD=...
SES_SMTP_HOST=                 # optional, defaults from SES_REGION
SES_SMTP_PORT=587
SES_AWS_ACCESS_KEY_ID=...      # SES API checks only; optional fallback to AWS_ACCESS_KEY_ID
SES_AWS_SECRET_ACCESS_KEY=...  # SES API checks only; optional fallback to AWS_SECRET_ACCESS_KEY
RESEND_API_KEY=...             # rollback only
MAILER_FROM="My App <team@example.com>"
MARKETING_MAILER_FROM="Alex from My App <alex@example.com>"
RESEND_MAILER_FROM="McRitchie Studio <team@mcritchie.studio>"
```

## SES Tasks

Consumer apps get shared SES helper tasks through the engine:

```bash
bin/rails ses:check
bin/rails "ses:verify_domain[example.com]"
```

The tasks use `SES_AWS_ACCESS_KEY_ID`, `SES_AWS_SECRET_ACCESS_KEY`, and
`SES_REGION` to query SES account status and print DKIM records. They fall back
to `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` only for older apps. Prefer the
`SES_AWS_*` names in production so an app's S3/ImageCache IAM user is never
mistaken for the SES verification user.

These are SES API credentials, not runtime SMTP credentials. Runtime delivery
still needs `SES_SMTP_USERNAME` and `SES_SMTP_PASSWORD`.

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
transport (`resend`, `ses`, `capture`, or the ActionMailer delivery method),
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
