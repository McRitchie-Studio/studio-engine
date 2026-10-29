# frozen_string_literal: true

module Studio
  # Who engine-sent mail comes from, and the production guard that refuses a
  # placeholder sender.
  #
  # Every app sends from team@mcritchie.studio under its own name (Alex
  # McRitchie's ruling, 2026-10-28); a client's own sending domain is a paid
  # tier upgrade, set through RESEND_MAILER_FROM or `resend_from:`.
  #
  # The guard exists because `rails new` writes app/mailers/application_mailer.rb
  # with `default from: "from@example.com"`. That class SHADOWS the engine's
  # ApplicationMailer, so every mailer, the magic link included, inherits the
  # placeholder, and Resend refuses every send. voicebox and moms-app both
  # shipped it and nobody could sign in. Pure Ruby, so the unit suite exercises
  # this file itself rather than a mirror of it.
  module MailSender
    TEAM_ADDRESS = "team@mcritchie.studio"
    FALLBACK_NAME = "McRitchie Studio"
    # The engine's own app_name default; an app that never named itself sends as
    # the platform rather than as "Studio".
    UNNAMED_APP = "Studio"

    # RFC 2606 reserved second-level domains, and any host under them.
    PLACEHOLDER_DOMAIN = /@(?:[a-z0-9-]+\.)*example\.(?:com|net|org)(?![a-z0-9.-])/i
    # RFC 5322 "specials": a display name carrying one must be quoted.
    DISPLAY_NAME_SPECIALS = /[()<>\[\]:;@\\,."]/

    class PlaceholderSenderError < StandardError; end

    module_function

    # "<app name> <team@mcritchie.studio>", the sender when nothing else is set.
    def default_for(app_name)
      name = app_name.to_s.strip
      name = FALLBACK_NAME if name.empty? || name == UNNAMED_APP
      "#{display_name(name)} <#{TEAM_ADDRESS}>"
    end

    def display_name(name)
      return name unless name.match?(DISPLAY_NAME_SPECIALS)

      %("#{name.gsub(/(["\\])/) { "\\#{Regexp.last_match(1)}" }}")
    end

    # True when any address in `from` (a String or an Array of them) sits on an
    # example.com / .net / .org domain.
    def placeholder?(from)
      Array(from).any? { |address| address.to_s.match?(PLACEHOLDER_DOMAIN) }
    end

    # The From: a mailer class would stamp on a message that sets none itself:
    # its `default from:`, with a proc default evaluated the way ActionMailer
    # evaluates it (inside a mailer instance).
    def resolve(mailer_class)
      from = mailer_class.default_params[:from]
      return from unless from.respond_to?(:call)

      mailer = mailer_class.send(:new)
      from.arity == 1 ? mailer.instance_exec(mailer, &from) : mailer.instance_exec(&from)
    end

    # Raises PlaceholderSenderError in production when any of `mailer_classes`
    # resolves to an example.com sender. Outside production it does nothing, so
    # a test or a desk that never sends real mail is never stopped by it.
    #
    # It runs at boot (the engine's after_initialize), and Heroku's build runs
    # `assets:precompile` in production, so a placeholder fails the BUILD: the
    # bad slug never releases and the running release keeps serving. A sender
    # that cannot be resolved at boot (its proc raises) is logged and skipped:
    # the guard refuses a placeholder it can see, and never a boot it cannot read.
    def verify!(mailer_classes:, rails_env:, logger: nil)
      return :skipped unless rails_env.to_s == "production"

      Array(mailer_classes).compact.uniq.each do |mailer_class|
        from =
          begin
            resolve(mailer_class)
          rescue StandardError => e
            logger&.warn("[mail] could not resolve #{mailer_class.name}'s default sender at boot (#{e.class}: #{e.message}); placeholder guard skipped it")
            next
          end
        raise PlaceholderSenderError, refusal(mailer_class, from) if placeholder?(from)
      end
      :verified
    end

    def refusal(mailer_class, from)
      <<~MSG.strip
        #{mailer_class.name} sends from #{Array(from).join(', ').inspect}, an example.com placeholder, and Resend refuses every such send (no magic link would arrive).
        The Rails scaffold's app/mailers/application_mailer.rb shadows the engine's ApplicationMailer. Delete it, or set:
          default from: -> { Studio.mailer_from.presence || "#{default_for(defined?(Studio) && Studio.respond_to?(:app_name) ? Studio.app_name : nil)}" }
        and pass resend_from: (not ses_from:) to Studio.mailer_from_for_transport in config/initializers/studio.rb. See studio-engine docs/NEW_APP_SETUP.md.
      MSG
    end
  end
end
