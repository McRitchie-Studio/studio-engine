# The standard sign-in card

The engine ships one sign-in card: Google, then "or", then the email magic
link. Sending the link flips the card to its link-sent step, with the shared
resend footer. The card comes as a page partial and as a modal. Both render
the same body, so they cannot drift apart.

Alex McRitchie asked for it on 2026-11-06, looking at the style guide's Email
field specimen: "this should use the standard auth component with Google and
Email." Before this, the engine shipped only the pieces
(`studio/modals/shared/_email_field` and `studio/modals/auth/_resend_footer`),
and each app built its own card from them.

| Partial | Use |
|---------|-----|
| `studio/auth/_sign_in_card` | A page: the app's heading, then the card |
| `studio/auth/_sign_in_modal` | A modal host's `<template x-if>`: a header, a ×, then the card |
| `studio/auth/_sign_in_body` | The shared inside. Render one of the two above, not this |

## On a page

```erb
<%= render "studio/auth/sign_in_card" %>

<%= render "studio/auth/sign_in_card",
      return_to: "/contests/42",
      subheading: "Sign in to play",
      preamble: "studio/modals/shared/age_attestation",
      extras: "shared/solana_wallet_connect" %>
```

## In a modal

```erb
<template x-if="$store.modals.current()?.id === 'sign-in'">
  <div><%= render "studio/auth/sign_in_modal", return_to: request.path %></div>
</template>
```

Open it with `$store.modals.open('sign-in')`. A page-scoped host passes its own
store: `modal_store: "dsModals"`. The store name is validated as a JavaScript
identifier (`Studio::JsIdentifier`), because the × and the footer's Close splice
it as a bare name.

## Locals

All are optional.

| Local | Default | What it does |
|-------|---------|--------------|
| `heading` | "Sign in to *App*" (`Studio::AuthLabels.to_app`) | The title |
| `subheading` | "New here? The same step creates your account." | The line under it. `nil` drops it |
| `return_to` | none | Where the visitor lands after sign-in. Only a plain in-app path is kept (`Studio::LocalPath.local?`); anything else is dropped. It rides the magic-link POST as `return_to` and the Google request URL as `?return_to=` |
| `preamble` | none | A partial above Google, such as an age attestation |
| `extras` | none | A partial after Google and before "or": extra providers, such as a Solana wallet button |
| `google` | `Studio.auth_method?(:google)` | Show Google |
| `magic_link` | `Studio.auth_method?(:magic_link)` | Show the email form |
| `magic_link_path` | the engine's `POST /magic_link` | Where the email form posts |
| `email` | none | Prefill for the email field |
| `google_label` · `send_label` | "Continue with Google" · "Email me a sign-in link" | Button words. The link noun follows `Studio.sign_in_label` |
| `logo` | `true` | Page card only: the app's "Auth Logo", when it has one |
| `modal_store` | `"modals"` | Modal only: the store the × and Close close |
| `dom_id` | `"sign-in-card"` · `"sign-in-modal"` | Prefix for the email field's id |
| `demo` | `false` | Post nothing (see below) |

A slot (`preamble`, `extras`) takes a partial path, `{ partial:, locals: }`, or
an Array of either. It is a named local, not a block: a partial cannot tell a
caller's block from the layout's content (`Studio::PartialBlock`).

## What it posts

- **Google** is a `button_to` POST to `/auth/google_oauth2`, with Turbo off.
  OmniAuth owns that path, and its request phase is POST-only and CSRF-checked.
  With `return_to`, the URL carries `?return_to=<path>`. The engine's own
  OmniAuth callback does not read it yet; an app whose callback reads
  `omniauth.params` (turf-monster does) gets it. When the app has no OAuth
  client yet, the card draws `studio/google_sign_in/_button`, which opens the
  setup modal instead (docs/GOOGLE_AUTH_SETUP.md). That button mounts one
  `googleSetupModals` host, and its rule is one per page: a page that renders
  this card while no OAuth client is set must not also render `sessions/new`'s
  button, or a second card. Demo mode never renders it.
- **Email** is a real `form_tag` to the magic-link endpoint, with `email` and
  `return_to`, so it works with no JavaScript. With JavaScript, the card posts
  the same fields by `fetch()` with `Accept: application/json` and the page's
  CSRF token, and shows the link-sent step only when the server answers
  success. A `503` with `error: "delivery_failed"` shows
  `Studio::MagicLinkIssuing::DELIVERY_FAILED`; a `429` asks the visitor to wait
  a minute; anything else shows a generic retry line. The card never prints a
  message from the response body.
- **Resend** posts the same request again. The footer counts down 60 seconds
  between sends.

## Demo mode

`demo: true` is for the style guide. Nothing posts:

- Google is a plain `type="button"` with no form. Pressing it shows a demo note.
- The email form has no action and no CSRF field, and the card's config has no
  endpoint. Send waits on a timer instead of `fetch()`.
- The link-sent step and the resend cooldown play as they do for real; the
  cooldown is 5 seconds, not 60.

`/admin/style` > Modals > Auth has one "Sign in" specimen. It opens
`studio/auth/_sign_in_modal` in demo mode on the guide's page-scoped host.

## The Alpine scope

The body's root `x-data` is the scope the resend footer resolves from:
`props.submitting`, `props.resendCooldown`, `props.resendError` and
`resendMagicLink()`. The server values (endpoint, return path, messages, button
words) go in as JSON in `data-sign-in-card`, which ERB escapes; no server value
is spliced into JavaScript source.

Focus follows the step: after Send, focus moves to the "Check your email"
heading; "Use a different email" moves it back to the field.

## Tests

- `test/views/sign_in_card_test.rb`: Google posts to `/auth/google_oauth2` with
  `return_to` and Turbo off, the email form posts to the magic-link endpoint,
  an off-site `return_to` is dropped, the slots render, and demo mode renders no
  live action.
- `e2e/style_sign_in_card.spec.js`: the style guide's specimen in a browser
  (no request reaches `/auth` or `/magic_link`, the link-sent step plays), and
  the live card on `/lab/sign_in_card` (what it sends, and the `503` answer).

## Adoption

The hub (`shared/_auth_card`, `modals/_auth`) and turf-monster
(`shared/_auth_card`, `modals/_auth`) still render their own cards. Moving them
to this one is follow-up work, one task per app.
