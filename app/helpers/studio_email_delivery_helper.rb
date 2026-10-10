module StudioEmailDeliveryHelper
  NON_DELIVERING_EMAIL_METHODS = %w[test file].freeze

  def email_delivery_banner_status
    details = email_delivery_banner_details

    "EMAIL SEND #{details.fetch(:sends_email)} · #{details.fetch(:transport)}"
  end

  def email_delivery_banner_details
    delivery_method = studio_email_delivery_method
    capture_enabled = Studio.local_email_capture?
    sends_email = studio_email_perform_deliveries? && !capture_enabled &&
                  !NON_DELIVERING_EMAIL_METHODS.include?(delivery_method)
    transport = email_delivery_transport_label(delivery_method, capture_enabled)
    connector = email_delivery_connector(delivery_method, transport)

    {
      connector: connector,
      connector_label: email_delivery_connector_label(connector),
      email_state: sends_email ? "Sending" : "Captured",
      provider_icon: email_delivery_provider_icon(connector),
      sends_email: sends_email,
      status_icon: sends_email ? "✅" : "❌",
      tooltip: "Connector: #{email_delivery_connector_label(connector)} · Emails: #{sends_email ? "Sending" : "Captured"}",
      transport: transport
    }
  end

  def email_delivery_transport_label(delivery_method = studio_email_delivery_method,
                                     capture_enabled = Studio.local_email_capture?)
    return "capture" if capture_enabled
    return "resend" if delivery_method == "resend"

    delivery_method.to_s.strip.empty? ? "unknown" : delivery_method
  end

  private

  def email_delivery_connector(delivery_method, transport)
    return "resend" if delivery_method == "resend" || transport == "resend"

    nil
  end

  def email_delivery_connector_label(connector)
    case connector
    when "resend" then "Resend"
    else "Unknown"
    end
  end

  def email_delivery_provider_icon(connector)
    case connector
    when "resend" then "resend-favicon.png"
    end
  end

  def studio_email_delivery_method
    return "unknown" unless defined?(ActionMailer)

    ActionMailer::Base.delivery_method.to_s
  end

  def studio_email_perform_deliveries?
    return false unless defined?(ActionMailer)

    ActionMailer::Base.perform_deliveries
  end
end
