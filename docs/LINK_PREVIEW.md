# Site identity and link previews

Every app on studio-engine has a **site identity**: a title, a description and an
image that say what the app is. Link previews (iMessage, Slack, Discord, X,
WhatsApp) are its first reader. Any page may override the preview with its own
picture and words, and the rest of the app can reuse the same copy.

Lifted from turf-monster (`OgHelper`, `SiteSetting`, `OgImageAttachable`, and the
app-local `LinkPreviewBot` from task `imessage-link-preview-fix`), which ran it in
production first.

## The pieces

| Piece | What it does |
|-------|--------------|
| `Studio::SiteIdentity` | One row per app: `title`, `description`, and an Active Storage `image`. Table `studio_site_identities`. |
| `/admin/link_preview` | Admin page that edits all three beside a live card drawn the way an unfurl draws it (image, domain, title, description). The image is cropped to 1200 × 630 in the shared crop modal. |
| `Studio.site_identity(base_url:)` · `studio_site_identity` | The resolved copy, `{ title:, description:, image_url: }`, for any reader: a meta description, share text, an email footer. |
| `link_preview(image:, title:, description:)` | The one page override. Call it from any view. |
| `layouts/studio/_head` | Emits the og:/twitter: tags (`studio_link_preview_tags`). |
| `Studio::LinkPreviewBots` | Controller concern: preview fetchers get a slim, head-only page. |
| `bin/rails g studio:site_identity` | The adoption step: migration, drafted copy, bot concern. |

## Resolution

Most specific first; the first present rung wins.

| | Page | Site identity (operator) | Drafted in code | Last resort |
|---|---|---|---|---|
| title | `link_preview title:`, then `content_for(:title)` | `SiteIdentity#title` | `Studio.site_title` | `Studio.app_name` |
| description | `link_preview description:`, then `content_for(:meta_description)` | `SiteIdentity#description` | `Studio.site_description` | none (tag omitted) |
| image | `link_preview image:`, then `content_for(:og_image)` | `SiteIdentity#image` | — | `Studio.link_preview_fallback_image` (`/og.png`) if the file exists, else none |

`Studio.site_identity` is the same chain without the page column.

`link_preview image:` takes a URL, a root-relative path, or an Active Storage
attachment or blob. `nil`, blank, or an attachment with nothing attached is a
blank rung, so `link_preview image: user.avatar` falls back to the site image when
the user has no avatar.

**The image URL is permanent.** Unfurlers cache the og:image URL and fetch it again
days later, so a signed, expiring URL breaks the preview. An image on a service
whose `public?` is true answers the service's own URL; any other service is served
through Rails' storage proxy route, a permanent URL on the app's own domain. To use
a public-read bucket, name its service:

```ruby
config.link_preview_image_service = :amazon_public   # read when the model loads
```

## The tags are opt-in by installation

`Studio.link_preview_tags` decides whether `layouts/studio/_head` emits the tags:

- `:auto` (the default) emits once the app has installed the
  `studio_site_identities` table **and** no template under its `app/views` writes
  its own `og:title` or `og:image`. The scan runs once per process; a hit is
  logged and named on `/admin/link_preview`. So an app that writes its own tags
  (turf-monster, cyvasse) gets no second set, even after
  `studio_engine:install:migrations` brings the table in.
- `true` always emits (the static fallback and the app name still answer).
- `false` never emits from the head. Use it while an app still writes its own
  tags, or to render `studio_link_preview_tags` somewhere else.

The scan is deliberately broad: any mention of `og:title` or `og:image` in a
template, a comment included, keeps `:auto` off. A false positive only keeps the
engine's tags off; set `true` to override it. An app that builds its own tags in
Ruby, where the scan cannot see them, sets `false` until it adopts.

## Preview bots and the 1 MiB limit

Apple's LinkPresentation (iMessage) aborts any HTML page over 1,048,576 bytes with
WebKitErrorDomain 102, "Frame load interrupted" (measured 2026-09-30: 1,048,000
bytes previewed, 1,049,000 failed). `include Studio::LinkPreviewBots` in
`ApplicationController`, and for a known fetcher the rendered page is replaced by
its `<title>`, meta and icon tags and a one-card body, with no script, style or
template. Because the slim page is built from the rendered page, a page's
`link_preview` override reaches it, and it works under any layout.

- The allow-list is `Studio::LinkPreview::BOT_TOKENS`: facebookexternalhit, Facebot,
  Twitterbot, Discordbot, Slackbot-LinkExpanding, LinkedInBot, WhatsApp/,
  TelegramBot, Applebot, SkypeUriPreview, redditbot, Embedly. iMessage sends
  `facebookexternalhit/1.1 Facebot Twitterbot/1.0`. In-app browsers (FBAN,
  LinkedInApp, "Twitter for iPhone") never match.
- A tag the page emits twice is kept once, the first occurrence.
- The slim response carries `X-Studio-Link-Preview: slim` and `Vary: User-Agent`.
- Only a 200 `text/html` GET or HEAD is rewritten. Anything else passes through.

## Drafting the copy

The convention: an agent drafts the title and description when it sets an app up,
and Alex edits them at `/admin/link_preview`. The generator writes the draft into
the initializer, where it is reviewed in the PR:

```bash
bin/rails g studio:site_identity --title "Turf Monster" \
  --description "Skill-based pick'em contests with transparent payouts."
```

A saved value on the page always wins over the draft. To carry a draft into the row
instead (from `db/seeds.rb` or a release task), use `seed!`, which fills only
blank fields and never overwrites an operator's edit:

```ruby
Studio::SiteIdentity.seed!(title: "Turf Monster", description: "Skill-based pick'em contests.")
```

## Configuration

| Setting | Default | Meaning |
|---------|---------|---------|
| `site_title` | `nil` (→ `app_name`) | Drafted title |
| `site_description` | `nil` | Drafted description |
| `link_preview_tags` | `:auto` | See above |
| `link_preview_image_service` | `nil` (app default) | Active Storage service for the image |
| `link_preview_fallback_image` | `"/og.png"` | Last image rung; used only if the file exists under `public/` |
| `draw_link_preview_routes` | `true` | Draw `/admin/link_preview` (`admin_link_preview_path`, `admin_link_preview_image_path`) |

## A page override, worked

The public user page (`/u/:username`, [`PUBLIC_USER_PAGE.md`](PUBLIC_USER_PAGE.md))
is the template for a per-page preview: `link_preview image: user.avatar, title:
user.username`. The avatar answers when attached, and the site image when not.
