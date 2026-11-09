# frozen_string_literal: true

module Studio
  # The one list of account roles every Studio app draws from (database audit
  # 2026-11-07, section 3). `users.role` holds one of these, guarded twice: by
  # Studio::Account's inclusion validation and by CHECK users_role_known, which
  # db/migrate/20261108170000_add_users_role_known_check.rb installs.
  #
  # A host may NARROW the list (`studio_roles %w[viewer admin]` in its User),
  # never widen it: a role the engine does not know means nothing to the
  # engine's admin checks, and a new one is added here, for every app at once.
  # Turf's old "user" spelling meant viewer and moved there.
  Roles = %w[viewer member admin].freeze

  # The role a new account takes when nothing says otherwise.
  DEFAULT_ROLE = "viewer"
end
