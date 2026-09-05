# User Model Contract

The Studio engine is a non-isolated Rails engine: it doesn't define `User`. Host apps must provide a `User` model that satisfies the contract below. If something is missing the engine will raise at boot via `Studio.validate_user_contract!` (see `lib/studio.rb`) with a clear message pointing back here.

## Required

These are the methods/attributes the engine actively calls. Missing one of these will block boot.

### Class methods
| Name | Used by | Notes |
|------|---------|-------|
| `User.find_by(id:)` | `Studio::ErrorHandling#current_user` | Standard ActiveRecord finder — automatic on any AR model. |
| `User.find_by(email:)` | `SessionsController#create` | Same. |

### Instance methods
| Name | Used by | Notes |
|------|---------|-------|
| `#admin?` | `require_admin`, several admin views | Boolean. Implement however your app wants (role enum, explicit column, etc.). |
| `#email` | `set_app_session`, SSO awareness | String. May be nil for wallet-only users — but then SSO is not available for them. |
| `#display_name` | `welcome_message` default proc, flash messages | String. Pure convenience helper — implement as `name.presence \|\| email.split('@').first`. |

### Instance methods — only if you enable password auth
| Name | Used by | Notes |
|------|---------|-------|
| `#authenticate(password)` | `SessionsController#create` | Provided by `has_secure_password`. Only required when `Studio.auth_methods` includes `:password`. |

### Class method — only if you enable Google OAuth
| Name | Used by | Notes |
|------|---------|-------|
| `User.from_omniauth(auth_hash)` | `OmniauthCallbacksController#create` | Should find-or-create by `(provider, uid)` and return the user. Wrap the find-or-create in `rescue ActiveRecord::RecordNotUnique` to handle concurrent OAuth callbacks for the same user. |

## Optional

The engine accesses these via `try:` or only inside config procs you write. They're soft contracts — implement them if your app exposes the concept, ignore them otherwise.

| Name | Used by | Notes |
|------|---------|-------|
| `#name` | `set_app_session` (via `try(:name)`) | If present, populates `session[:sso_name]`. |
| `#provider` | `set_app_session` | OAuth provider string (e.g. `"google"`). |
| `#first_name` (+ writer) | `Studio::OnboardingController`, `Studio::ProfilesController`, `Studio.first_name_outstanding?` | The name ask is SKIPPED entirely on a host without the column, rather than raising — `mcritchie-industries` ran that way for weeks. Install it with the engine's standard-columns migration. |
| `#last_name` (+ writer) | `Studio::OnboardingController`, `Studio::ProfilesController` | Written ONLY where the column exists. The standard-columns migration deliberately does NOT add it (making it universal is a separate fleet change), so `mcritchie-industries`, `moms-app` and `acquisition-studio` run without it today and get a first-name-only profile row. |
| `#uid` | `set_app_session` | OAuth provider UID. |
| `#wallet_address` or `#solana_address` | `Studio.user_wallet_address`, `set_app_session`, `SessionContext#address` | For wallet-auth apps. Override with `Studio.wallet_address_method = :your_method` if the app uses another helper. |
| `#role=` | `configure_sso_user` proc in host app | Only required if the host's `Studio.configure_sso_user` proc sets `user.role = ...`. |
| `#balance_cents=` | `configure_sso_user` proc | Same — only if the host proc uses it. |

### Deriving the name halves

Every consumer derives `first_name`/`last_name` from `name` in a `before_save`:

```ruby
before_save :set_name_parts, if: -> { name_changed? }
```

Two things about that are the host's problem, and the engine now helps with both.

1. **A callback-free writer owes the same derivation.** `Studio::OnboardingController`
   writes with `update_columns` on purpose — `Sluggable`'s `before_save :set_slug`
   is UNGATED, so a full save right after a `name` write re-points the slug the
   account answers on. Any writer in that position should derive with
   **`Studio::NameParts.from(name)`** (`lib/studio/name_parts.rb`) rather than
   retyping the split, so every door leaves the row split the same way. A host's
   own `set_name_parts` may delegate to it too.
2. **`last_name` is OMITTED, not nil, for a one-word name.** That is what leaves a
   surname already on file standing when someone answers a first-name prompt with
   one word. A hash that nulled it would disagree with the callback in the
   opposite direction.

## Recommended attributes (DB columns)

The engine doesn't care about DB shape directly, but in practice every consumer ships:
- `name:string`
- `email:string` (unique-indexed, nullable for wallet-only apps)
- `password_digest:string` only when enabling password auth
- `provider:string`, `uid:string` (OmniAuth)
- `role:string` or `role:integer` (for `admin?`)
- `slug:string` (for `Sluggable`-friendly URLs)
- `first_name:string` (and `last_name:string` where the app wants the surname) — the standard-columns migration installs `first_name`

## Example minimal compliant model

```ruby
class User < ApplicationRecord
  include Sluggable                  # from the engine
  has_many :error_logs, as: :target  # if you want to associate logged errors

  def admin?
    role == "admin"
  end

  def display_name
    name.presence || email&.split("@")&.first || "User"
  end

  def name_slug
    (name.presence || email.to_s.split("@").first).parameterize
  end

  def self.from_omniauth(auth, email_verified: false)
    user = find_by(provider: auth["provider"], uid: auth["uid"])
    return user if user

    email = auth.dig("info", "email")
    if email.present? && (existing = find_by(email: email))
      return :email_not_verified unless email_verified

      existing.update!(provider: auth["provider"], uid: auth["uid"])
      return existing
    end

    create!(
      email: email,
      name: auth.dig("info", "name"),
      provider: auth["provider"],
      uid: auth["uid"]
    )
  rescue ActiveRecord::RecordNotUnique
    find_by(email: email) || find_by(provider: auth["provider"], uid: auth["uid"])
  end
end
```

Only add `has_secure_password validations: false` when the host app deliberately
enables `Studio.auth_methods << :password` and has a `password_digest` column.

## Why this exists

Before 2026-05-17 (audit Tier 2 #16) the engine called these methods with no formal contract, so new apps onboarding to the engine would hit cryptic `NoMethodError` at runtime. The boot-time validator now catches missing methods early and points at this doc.

To temporarily skip the validator (e.g. during a migration that intentionally breaks the contract), set `Studio.validate_user_contract = false` in `config/initializers/studio.rb`.
