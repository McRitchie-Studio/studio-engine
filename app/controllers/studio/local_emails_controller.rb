module Studio
  class LocalEmailsController < ApplicationController
    skip_before_action :require_authentication, raise: false
    layout false

    before_action :require_local_development!

    def index
      @deliveries = delivery_records.map { |record| serialize_delivery(record) }

      respond_to do |format|
        format.html
        format.json do
          render json: {
            capture_enabled: Studio.local_email_capture?,
            inbox_url: request.original_url.sub(/\.json\z/, ""),
            deliveries: @deliveries
          }
        end
      end
    end

    private

    def require_local_development!
      head :not_found unless Studio.local_tool_enabled?(request_local: request.local?)
    end

    def delivery_records
      klass = delivery_class
      return [] unless klass

      klass.recent.limit(50)
    end

    def delivery_class
      if Object.const_defined?(:EmailDelivery, false)
        return Object.const_get(:EmailDelivery, false)
      end

      if Studio.const_defined?(:EmailDelivery, false) && Studio::EmailDelivery.respond_to?(:available?) && Studio::EmailDelivery.available?
        return Studio::EmailDelivery
      end

      nil
    end

    def serialize_delivery(record)
      args = deserialize_args(record.args)
      kwargs = deserialize_kwargs(record.kwargs)
      {
        id: record.id,
        email_key: record.email_key,
        mailer: record.mailer,
        action: record.action,
        to: record.to,
        sent: record.sent?,
        sent_at: record.sent_at,
        error: record.error,
        created_at: record.created_at,
        action_url: local_action_url(record, args),
        args_preview: args.map { |arg| preview_value(arg) },
        kwargs_preview: kwargs.transform_values { |value| preview_value(value) }
      }
    end

    def deserialize_args(value)
      ActiveJob::Arguments.deserialize(value || [])
    rescue StandardError
      []
    end

    def deserialize_kwargs(value)
      deserialized = ActiveJob::Arguments.deserialize([value || {}]).first
      deserialized.respond_to?(:symbolize_keys) ? deserialized.symbolize_keys : {}
    rescue StandardError
      {}
    end

    def local_action_url(record, args)
      token = args[1].to_s
      return if token.empty?

      path =
        case record.email_key
        when /#magic_link\z/
          # /l/<token> only when the app actually emails /l (Studio::Link store +
          # /l routes drawn); otherwise the legacy /magic_link/<token> — covers the
          # signed store AND apps like turf-monster that keep their own /magic_link.
          base = Studio.magic_link_via_l_route? ? "/l" : "/magic_link"
          "#{base}/#{ERB::Util.url_encode(token)}"
        when /#email_verification\z/
          "/email_verification/#{ERB::Util.url_encode(token)}"
        when /#wallet_export\z/
          "/account/wallet/export/#{ERB::Util.url_encode(token)}"
        when /#email_change_confirmation\z/
          "/account/email/confirm/#{ERB::Util.url_encode(token)}"
        end

      "#{request.base_url}#{path}" if path
    end

    def preview_value(value)
      case value
      when String, Numeric, TrueClass, FalseClass, NilClass
        value
      else
        value.respond_to?(:to_global_id) ? value.to_global_id.to_s : value.to_s
      end
    end
  end
end
