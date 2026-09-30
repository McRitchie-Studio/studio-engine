# frozen_string_literal: true

module Studio
  # /admin/link_preview — the operator edits the SITE IDENTITY (Studio::
  # SiteIdentity): the image, title and description an unfurl shows for any page
  # that does not name its own, and the copy Studio.site_identity hands any
  # other reader. All three on one page, beside a live card drawn the way an
  # unfurl draws it.
  #
  # A plain host-inherited controller whose view is a bare content wrapper, like
  # /admin/geo and /admin/emails, so it renders inside each host's application
  # layout. Lifted from turf-monster's admin dashboard (update_link_preview and
  # update_link_preview_image), which ran it in production first.
  #
  # The image and the words post SEPARATELY: the cropper submits a form holding
  # only the image, the text form holds only the words. So #update changes only
  # the fields a request actually carried.
  class SiteIdentitiesController < ApplicationController
    before_action :require_admin

    MAX_IMAGE_BYTES = 8.megabytes
    IMAGE_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze

    def edit
      @installed = Studio::SiteIdentity.table_ready?
      @setting = Studio::SiteIdentity.current
      @uploads_available = @installed && @setting.respond_to?(:image)
      @default_image_url = default_image_url
      @static_image_url = static_image_url
      @domain = request.host
    end

    def update
      return redirect_to(admin_link_preview_path, alert: not_installed_message, status: :see_other) unless installed?

      attrs = params.fetch(:site_identity, {})
      file = attrs[:image]

      if attrs.key?(:image) && !valid_image?(file)
        message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, WebP or GIF under 8 MB."
        return redirect_to admin_link_preview_path, alert: message, status: :see_other
      end

      setting = Studio::SiteIdentity.current!
      rescue_and_log(target: setting) do
        setting.title = attrs[:title].to_s.strip.presence if attrs.key?(:title)
        setting.description = attrs[:description].to_s.strip.presence if attrs.key?(:description)
        setting.save!
        setting.image.attach(file) if file.present?
        # An attach does not touch the row, so after_commit does not fire for it.
        Studio::SiteIdentity.bust_cache!
      end

      redirect_to admin_link_preview_path, status: :see_other,
                                           notice: file.present? ? "Default link-preview image updated." : "Link-preview defaults updated."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_link_preview_path, status: :see_other, alert: e.record.errors.full_messages.to_sentence
    rescue StandardError
      redirect_to admin_link_preview_path, status: :see_other, alert: "Couldn't save the link preview. Please try again."
    end

    # DELETE /admin/link_preview/image — drop the uploaded default, so previews
    # fall back to the static image (or none).
    def destroy_image
      return redirect_to(admin_link_preview_path, alert: not_installed_message, status: :see_other) unless installed?

      setting = Studio::SiteIdentity.current
      if setting.persisted? && setting.image_attached?
        rescue_and_log(target: setting) do
          setting.image.purge
          Studio::SiteIdentity.bust_cache!
        end
      end

      redirect_to admin_link_preview_path, status: :see_other, notice: "Default link-preview image removed."
    rescue StandardError
      redirect_to admin_link_preview_path, status: :see_other, alert: "Couldn't remove the image. Please try again."
    end

    private

    def installed?
      Studio::SiteIdentity.table_ready?
    end

    def not_installed_message
      "Install the site identity table first: bin/rails g studio:site_identity && bin/rails db:migrate"
    end

    def valid_image?(file)
      file.respond_to?(:content_type) && IMAGE_TYPES.include?(file.content_type.to_s) &&
        file.respond_to?(:size) && file.size.to_i.positive? && file.size <= MAX_IMAGE_BYTES
    end

    # The uploaded image as the card shows it: the same URL the head emits.
    def default_image_url
      stored = Studio::SiteIdentity.stored
      Studio::LinkPreview.absolute_url(stored[:image_url] || stored[:image_path], base_url: request.base_url)
    rescue StandardError
      nil
    end

    def static_image_url
      Studio::LinkPreview.absolute_url(Studio::SiteIdentity.static_image, base_url: request.base_url)
    end
  end
end
