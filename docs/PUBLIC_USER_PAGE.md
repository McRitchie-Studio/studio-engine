# Public user page

Every app on studio-engine can serve a public page for each user at
`/u/:username`. It is where a click on a username anywhere in a Studio app leads.

## What it shows

The avatar and the username. Nothing else: no name, first name, email or wallet.
The avatar is `components/_avatar` at size `xl` (the initials circle when there is
no picture), with the username as its alt text.

Its link preview (iMessage, Slack, Discord, X) uses the primitive in
[`LINK_PREVIEW.md`](LINK_PREVIEW.md): the page calls
`link_preview image: user.avatar, title: username`. When the user has an avatar,
the unfurl shows it. When they do not, the empty attachment is a blank rung and
the site identity's image answers, then `public/og.png`. The description is the
site identity's.

The avatar's og:image URL is permanent, never a signed expiring one. It follows
the same rule as the site image: a public Active Storage service answers its own
URL, and any other service goes through Rails' storage proxy on the app's domain.
An app that includes `Studio::LinkPreviewBots` serves preview fetchers the slim
page, which carries the same tags.

## Lookup

- **Case-insensitive.** `/u/Alex` and `/u/alex` are the same page. An exact
  spelling wins first, for apps whose case-folded usernames are not unique.
- **`username` only.** The lookup never reads the email or the slug (the hub
  apps key the slug on the email), so the page cannot tell a stranger whether an
  address has an account.
- **Hiding an account.** Define `public_profile_visible?` on `User`; `false` makes
  that account's page a 404 (a frozen, merged or banned account, say).
- **Unknown usernames** get a friendly page with a real `404` status. Every miss
  renders the same page, whether the name is unknown, hidden, or the app has no
  `username` column.

The page is public: it skips `require_authentication`, so apps that gate every
controller (mcritchie-industries, cyvasse) still serve it signed out. It renders
inside the host's own layout.

## Linking to it

| Helper | Answers |
|--------|---------|
| `studio_user_profile_path(user)` | `"/u/alex"`, or `nil` |
| `studio_user_profile_url(user)` | the absolute URL, or `nil` |
| `link_to_user_profile(user, text = nil, **html_options, &block)` | a link, or the text in a plain `<span>` |
| `studio_public_user_path(username:)` | the raw route helper |

Each takes a user or a username string. The text defaults to `display_name`.
The helpers answer `nil` (and `link_to_user_profile` renders a `<span>`) when the
route is not drawn or the user has no username, so a view can call them for any
user without checking first. The logic lives in `Studio::PublicUser`.

```erb
<%= link_to_user_profile(entry.user, class: "font-semibold hover:underline") %>
<%= link_to_user_profile(user) do %><%= render "components/avatar", user: user, size: "sm" %><% end %>
```

## Adopting

The route is opt-in, like the engine's other route surfaces, so an app that owns
`/u` is not broken:

```ruby
# config/initializers/studio.rb
config.draw_public_user_routes = true
```

The app needs a `username` column on `users`. Cyvasse and turf-monster have one;
mcritchie-studio and mcritchie-industries do not yet. Add it with a
case-insensitive unique index before turning the flag on:

```ruby
add_column :users, :username, :string
add_index :users, "lower(username)", unique: true, where: "username IS NOT NULL",
          name: "index_users_on_lower_username"
```

`Studio::UsernameGenerator.generate` drafts one (`plant-animal`) for a backfill.
