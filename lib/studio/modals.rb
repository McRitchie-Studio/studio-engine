# frozen_string_literal: true

module Studio
  # The on-demand modal registry: modals the shared host (studio/modals/_host)
  # fetches the first time they open, instead of the layout rendering every
  # template into every page.
  #
  #   # config/initializers/studio.rb
  #   Studio.modals.register :contest_rules, partial: "modals/contest_rules"
  #   Studio.modals.register :wallet_setup,  partial: "modals/wallet_setup",
  #                          auth: :user, locals: :wallet_setup_modal_locals
  #   Studio.modals.register :auth,          partial: "modals/auth", prefetch: true
  #
  # A registered id is served by GET /_studio/modals/:id
  # (Studio::ModalsController) and opened with the same
  # $store.modals.open(id, props) call as before. Render it ONLY through the
  # registry: an id that the layout still renders AND the registry names would
  # mount twice. Every id the registry does not name behaves as it always did.
  #
  # Options:
  #   partial:  the content partial, rendered exactly as the layout rendered it
  #             (one root element; see the README's "Modal host" rules).
  #   auth:     :any (default) or :user. A :user modal answers 401 to a
  #             signed-out request, and is never prefetched for one.
  #   prefetch: true fetches the modal when the browser idles after load, for a
  #             modal that should open with no wait (the sign-in card).
  #   locals:   the partial's locals. A Hash, a Symbol naming a helper the view
  #             answers (Turf's existing *_modal_locals helpers), or a callable
  #             taking the view. Resolved per request, inside the view.
  module Modals
    AUTH_LEVELS = %i[any user].freeze

    # The id lands inside a single-quoted JavaScript string in the host's x-if,
    # and in a URL path segment, so it is held to a shape that needs no escaping
    # in either place.
    ID_FORMAT = /\A[a-z0-9][a-z0-9_-]*\z/

    Entry = Struct.new(:id, :partial, :auth, :prefetch, :locals, keyword_init: true) do
      def user_only? = auth == :user

      # The locals for one render, resolved in that render's view.
      def locals_for(view)
        resolved =
          case locals
          when nil then {}
          when Hash then locals
          when Symbol, String then view.public_send(locals)
          else locals.arity.zero? ? view.instance_exec(&locals) : locals.call(view)
          end
        raise ArgumentError, "Studio.modals #{id}: locals must resolve to a Hash, got #{resolved.class}" unless resolved.is_a?(Hash)

        resolved
      end
    end

    class Registry
      def initialize
        @entries = {}
      end

      def register(id, partial:, auth: :any, prefetch: false, locals: nil)
        key = id.to_s
        raise ArgumentError, "Studio.modals: id #{id.inspect} must match #{ID_FORMAT.inspect}" unless key.match?(ID_FORMAT)
        raise ArgumentError, "Studio.modals #{key}: partial is required" if partial.to_s.strip.empty?
        raise ArgumentError, "Studio.modals #{key}: auth must be one of #{AUTH_LEVELS.inspect}" unless AUTH_LEVELS.include?(auth)
        unless locals.nil? || locals.is_a?(Hash) || locals.is_a?(Symbol) || locals.is_a?(String) || locals.respond_to?(:call)
          raise ArgumentError, "Studio.modals #{key}: locals must be a Hash, a helper name or a callable"
        end

        @entries[key] = Entry.new(id: key, partial: partial.to_s, auth: auth, prefetch: prefetch == true, locals: locals)
      end

      def [](id) = @entries[id.to_s]
      def registered?(id) = @entries.key?(id.to_s)
      def ids = @entries.keys
      def entries = @entries.values
      def any? = @entries.any?
      def empty? = @entries.empty?

      # Removes one id, or every id. For tests and for a host that registers
      # conditionally on reload.
      def unregister(id) = @entries.delete(id.to_s)
      def clear! = @entries.clear

      # What the host template advertises to studio/modal_host. Every id, so a
      # signed-out open of a :user modal still reaches the endpoint and shows
      # the error card; prefetch only what this viewer may load.
      def client_config(url_template:, logged_in:)
        {
          url: url_template,
          ids: ids,
          prefetch: entries.select { |e| e.prefetch && (!e.user_only? || logged_in) }.map(&:id)
        }
      end
    end
  end

  def self.modals
    @modals ||= Modals::Registry.new
  end
end
