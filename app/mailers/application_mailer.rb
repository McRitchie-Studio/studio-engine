class ApplicationMailer < ActionMailer::Base
  # Resolved per-message (proc default) so it picks up Studio.mailer_from set in
  # the host's config/initializers/studio.rb, with an ENV fallback. No layout is
  # forced — ActionMailer renders bare if the host ships no mailer layout, and a
  # host that defines its own ApplicationMailer (e.g. turf-monster) wins outright.
  #
  # Unset, it is "<Studio.app_name> <team@mcritchie.studio>": every app sends
  # from team@ under its own name (a client's own domain is a tier upgrade).
  default from: -> { Studio.mailer_from.presence || ENV["MAILER_FROM"].presence || Studio.default_mailer_from }
end
