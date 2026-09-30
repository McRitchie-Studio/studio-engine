# frozen_string_literal: true

module Studio
  # Serve link-preview fetchers (iMessage, Slack, Discord, X, WhatsApp...) a
  # SLIM document — the page's own identity tags and a one-card body — instead
  # of the full page.
  #
  #   class ApplicationController < ActionController::Base
  #     include Studio::LinkPreviewBots
  #   end
  #
  # WHY: Apple's LinkPresentation (the iMessage unfurler) aborts any HTML page
  # over 1 MiB (WebKitErrorDomain 102, "Frame load interrupted"; measured
  # 2026-09-30: 1,048,000 bytes previewed, 1,049,000 failed). A page carrying a
  # big inline script or template passes that without anyone noticing, and every
  # link to it stops previewing in Messages while Discord keeps working.
  #
  # HOW: the action and its view run as usual — so a page's `link_preview`
  # override is set — and the full page renders. Then, for a known fetcher only,
  # the body is replaced by Studio::LinkPreview.slim_document, which lifts the
  # <title>, meta and icon tags out of that page's <head> and drops every script,
  # style and template. Built from the rendered page, the slim document cannot
  # drift from what a person's page says, and it works under ANY layout.
  #
  # DUPLICATE-SAFE: a tag the page emits twice (an app's own og tags and the
  # engine's) reaches the fetcher once, the first occurrence.
  #
  # People, in-app browsers and unknown agents are never matched and always get
  # the full page. The allow-list is Studio::LinkPreview::BOT_TOKENS.
  module LinkPreviewBots
    extend ActiveSupport::Concern

    SLIM_HEADER = "X-Studio-Link-Preview"

    included do
      after_action :serve_link_preview_slim_document

      helper_method :link_preview_bot_request? if respond_to?(:helper_method)
    end

    # A preview fetcher reading a page. No format check: an unfurler often sends
    # `Accept: */*`, which Rails reads as Mime::ALL rather than html, though the
    # response it gets is HTML — the after_action checks the RESPONSE instead.
    def link_preview_bot_request?
      (request.get? || request.head?) && Studio::LinkPreview.bot?(request.user_agent)
    end

    private

    def serve_link_preview_slim_document
      return unless link_preview_bot_request?
      return unless response.status == 200
      return unless response.media_type == "text/html"

      body = response.body
      return unless body.is_a?(String) && !body.empty?

      response.body = Studio::LinkPreview.slim_document(body, url: request.original_url)
      response.headers[SLIM_HEADER] = "slim"
      # A shared cache must never hand the slim page to a person.
      response.headers["Vary"] = [response.headers["Vary"], "User-Agent"].compact.join(", ")
    rescue StandardError => e
      # The full page is still a valid (if large) answer; never 500 a fetcher.
      Rails.logger&.warn("[studio.link_preview] slim render skipped: #{e.class}: #{e.message}")
    end
  end
end
