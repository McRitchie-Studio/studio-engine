# Google OAuth Setup

How to add Google sign-in to a new McRitchie app.

## Prerequisites

- A Google Cloud project with OAuth 2.0 credentials
- An app-local `.env` file, hydrated from McRitchie Studio's credential inventory or the app's hosting config

## Shared Credentials

Each local app should carry its own `.env`:

```env
GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-your-secret
```

Apps load this via `dotenv-rails` in development/test. In production, set these
as config vars on the deployed app. McRitchie Studio's agent credential docs are
the source of truth for 1Password item names.

## Steps for a New App

### 1. Add gems to Gemfile

```ruby
# Google OAuth
gem "omniauth"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection", "~> 1.0"

# Environment variables (if not already present)
gem "dotenv-rails", groups: [:development, :test]
```

Run `bundle install`.

### 2. Create OmniAuth initializer

Create `config/initializers/omniauth.rb`:

```ruby
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
    ENV["GOOGLE_CLIENT_ID"],
    ENV["GOOGLE_CLIENT_SECRET"],
    scope: "email,profile",
    prompt: "select_account"
end

OmniAuth.config.allowed_request_methods = [:post]
```

Keep the OmniAuth request phase POST-only. If an app needs a popup or custom
entrypoint, render an auto-submitting POST form to `/auth/google_oauth2`
instead of redirecting a GET request into OmniAuth.

### 3. Add `from_omniauth` to User model

Passwordless apps should not create throwaway passwords for Google users. The
engine passes `email_verified:` after server-side tokeninfo validation, so use
that signal when linking Google to an existing email account.

```ruby
def self.from_omniauth(auth, email_verified: false)
  user = find_by(provider: auth.provider, uid: auth.uid)
  return user if user

  email = auth.info.email
  if email.present? && (existing = find_by(email: email))
    return :email_not_verified unless email_verified

    existing.update!(
      provider: auth.provider,
      uid: auth.uid,
      email_verified_at: existing.email_verified_at || Time.current
    )
    return existing
  end

  create!(
    email: email,
    name: auth.info.name,
    provider: auth.provider,
    uid: auth.uid,
    email_verified_at: email_verified ? Time.current : nil
  )
rescue ActiveRecord::RecordNotUnique
  find_by(email: auth.info.email) || find_by(provider: auth.provider, uid: auth.uid)
end
```

### 4. Ensure User model has provider/uid columns

```ruby
# Migration
add_column :users, :provider, :string
add_column :users, :uid, :string
add_column :users, :email_verified_at, :datetime
```

### 5. Add redirect URI in Google Cloud Console

Go to [Google Cloud Console](https://console.cloud.google.com/apis/credentials) → your OAuth 2.0 Client ID → Authorized redirect URIs.

Add the callback URL for your new app:

| Environment | URI |
|------------|-----|
| Development | `http://localhost:{PORT}/auth/google_oauth2/callback` |
| Production | `https://{subdomain}.mcritchie.studio/auth/google_oauth2/callback` |

**Current apps:**

| App | Port | Dev URI | Prod URI |
|-----|------|---------|----------|
| McRitchie Studio | 3000 | `http://localhost:3000/auth/google_oauth2/callback` | `https://mcritchie.studio/auth/google_oauth2/callback` |
| Turf Monster | 3100 | `http://localhost:3100/auth/google_oauth2/callback` | `https://turfmonster.media/auth/google_oauth2/callback` |
| Tax Studio | 3200 | `http://localhost:3200/auth/google_oauth2/callback` | `https://tax.mcritchie.studio/auth/google_oauth2/callback` |

Keep legacy callback aliases such as `https://app.mcritchie.studio/...` and
`https://app.turfmonster.media/...` registered only while provider dashboards or
old links still need them.

### 6. Routes (already handled)

`Studio.routes(self)` draws the OAuth callback route automatically:

```ruby
get "auth/:provider/callback", to: "omniauth_callbacks#create"
get "auth/failure", to: "omniauth_callbacks#failure"
```

The engine's `OmniauthCallbacksController` handles the callback. Override it locally if you need custom logic (e.g. Turf Monster's account merge flow).

### 7. Restart the server

OmniAuth middleware is loaded at boot — restart required after adding the initializer.

## Production (Heroku)

```bash
heroku config:set GOOGLE_CLIENT_ID=your-client-id --app your-app
heroku config:set GOOGLE_CLIENT_SECRET=your-secret --app your-app
```

## Troubleshooting

- **"No route matches [POST] /auth/google_oauth2"** — missing OmniAuth gems or initializer. Run `bundle install` and restart.
- **GET `/auth/google_oauth2` does not start OAuth** — expected. Use a POST form or `button_to` for the request phase.
- **"redirect_uri_mismatch"** — the callback URI isn't registered in Google Cloud Console. Add it (see step 5).
- **Credentials not loading** — ensure `dotenv-rails` is in the Gemfile and the app-local `.env` exists.
