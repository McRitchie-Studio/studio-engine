# Studio Cable — shared websocket / Redis primitive

Realtime in the McRitchie ecosystem is **Turbo Streams over ActionCable**, backed
by Redis. This primitive gives every host app the *correct* setup in one place, so
no app has to re-derive (or forget) it. It exists because forgetting it caused a
production outage — see the post-mortem at the bottom.

Two pieces:

| Piece | What it is | Used by |
|---|---|---|
| `Studio::Redis` | The single source of Redis **connection** truth (URL + TLS) | `cable.yml`, `cache_store`, Sidekiq |
| `Studio::Cable.safe_broadcast` | Best-effort **broadcast guard** (StandardError **and** ScriptError) | every broadcast |

The engine also declares **`redis`** and **`turbo-rails`** as dependencies, so a
consuming app can't ship a cable feature with the gem missing.

## 1. `Studio::Redis` — connection config (the TLS gotcha, solved once)

Heroku Redis serves `rediss://` (TLS) with a **self-signed** cert. `redis-client`
verifies peer certs by default, so the connection is **silently rejected** — the
`/cable` socket still upgrades to 101, but broadcasts never reach subscribers and
the cache silently no-ops. The fix is `ssl_params: { verify_mode: VERIFY_NONE }`,
which `Studio::Redis.options` applies automatically for any `rediss://` URL.

```ruby
Studio::Redis.url                              # ENV["REDIS_URL"] || "redis://localhost:6379/1"
Studio::Redis.tls?                             # true for rediss://
Studio::Redis.options                          # { url:, ssl_params: {…} } when TLS, else { url: }
Studio::Redis.options(namespace: "app-cache")  # extras merge through
```

Use it everywhere Redis is configured:

**`config/cable.yml`**
```erb
<% opts = Studio::Redis.options %>
production:
  adapter: redis
  url: <%= opts[:url] %>
  channel_prefix: <app>_production
  <% if opts[:ssl_params] %>
  ssl_params:
    verify_mode: <%= OpenSSL::SSL::VERIFY_NONE %>
  <% end %>
```

**`config/environments/production.rb`** (cache_store) and **`config/initializers/sidekiq.rb`**
```ruby
config.cache_store = :redis_cache_store, Studio::Redis.options(namespace: "app-cache", expires_in: 90.minutes)
# Sidekiq.configure_server { |c| c.redis = Studio::Redis.options }
```

## 2. `Studio::Cable.safe_broadcast` — never break the caller

```ruby
Studio::Cable.safe_broadcast { ActionCable.server.broadcast("stream", payload) }
```

Catches `StandardError` **and** `ScriptError`. A missing/misconfigured cable adapter
raises `Gem::LoadError`, which is a `ScriptError` — *not* a `StandardError` — so a
plain `rescue StandardError` does **not** catch it. In an `after_commit` that means
the exception escapes and 500s the write. This guard closes that hole. Failures are
captured to `ErrorLog` (if the host defines it) or logged; it returns `nil`.

## 3. Broadcasting from a model

Wrap turbo-rails' `broadcast_*_to` (already on every model, because turbo-rails
mixes `Turbo::Broadcastable` into `ActiveRecord::Base`) in the guard, so a cable
hiccup can never break a save:

```ruby
class Task < ApplicationRecord
  after_create_commit do
    Studio::Cable.safe_broadcast do
      broadcast_replace_to [:board], target: "card_#{id}",
                           partial: "tasks/card", locals: { task: self }
    end
  end
end
```

## Heroku readiness (do this before a host app's realtime can work)

The primitive makes the *config* correct, but ActionCable still needs a Redis
**server**:

1. **Provision Redis:** `heroku addons:create heroku-redis:mini -a <app>` — sets
   `REDIS_URL` (a `rediss://` URL; `Studio::Redis` then applies the TLS handling).
2. Confirm `heroku config:get REDIS_URL -a <app>` is set.
3. With one web dyno the in-process pubsub would suffice, but the `redis` adapter is
   correct for multiple puma workers / dynos — keep it.

Without a Redis addon, broadcasts degrade silently (the board still renders; updates
just don't push) — they no longer crash, because of `safe_broadcast`.

## Post-mortem — why this primitive exists (2026-06-24)

`mcritchie-studio` shipped its first ActionCable channel (the live `/deployments`
board, #171) with **none** of the above: no `redis` gem, no TLS cable config, no
Redis addon. Its `after_create_commit` board broadcast fired on every task write →
`ActionCable.server.broadcast` lazy-loaded the redis adapter → `Gem::LoadError`
(`redis is not part of the bundle`). The broadcaster's `rescue StandardError`
**didn't** catch it (`Gem::LoadError < ScriptError`, not `StandardError`), so the
exception escaped the after-commit and **500'd every task create and stage move in
production**. Turf Monster had the correct setup the whole time — but copied by
hand into three places (`cable.yml`, `cache_store`, Sidekiq). This primitive turns
"remember to do all of that, correctly, in every app" into "include the engine."
