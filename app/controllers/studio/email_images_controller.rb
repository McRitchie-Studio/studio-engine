module Studio
  # DEPRECATED — superseded by Studio::EmailsController (/admin/emails), which
  # shows every registered email with its live image, says whether that image is
  # the inherited default or app-owned, and uploads through the crop modal.
  #
  # Kept alive for ONE release on purpose, not by neglect. consumer-ci.yml checks
  # out each consumer repo with no `ref:` — i.e. its DEFAULT BRANCH — and runs
  # that suite against the engine PR. mcritchie-studio and turf-monster both have
  # tests on `main` that drive this page and its admin_email_image_path helper,
  # so deleting it here would redden their lanes from the moment the PR opens,
  # and nothing inside the engine PR could fix it: the consumer PRs would have to
  # travel accepted -> release -> main in BOTH apps before this could go green.
  #
  # So the retirement is staged: this release adds /admin/emails and leaves this
  # page working; each app's adoption task moves its link and its tests; a later
  # engine minor deletes this file, its view, and its two routes once no
  # consumer's main references them.
  #
  # It is not frozen in its broken state, though — see #index.
  class EmailImagesController < ApplicationController
    before_action :require_admin

    MAX_BYTES = 8.megabytes

    def index
      @variants = Studio::EmailImage.variants
    end

    # The canonical page this one is being retired in favour of. Rendered as a
    # banner at the top of the old view so an admin who lands here by a stale
    # link or bookmark is walked forward rather than left on the worse page.
    def successor_path
      admin_emails_path
    end
    helper_method :successor_path

    # PATCH /admin/email_images/:variant — upload/replace a banner.
    def update
      variant = params[:variant].to_s
      return head :not_found unless Studio::EmailImage.known?(variant)

      file = params[:image]
      unless valid_image?(file)
        message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, or WebP under 8 MB."
        return redirect_to admin_email_images_path, alert: message, status: :see_other
      end

      rescue_and_log do
        Studio::EmailImage.store(variant, io: file, content_type: file.content_type)
        redirect_to admin_email_images_path, notice: "#{Studio::EmailImage.label(variant)} banner updated."
      end
    rescue StandardError
      redirect_to admin_email_images_path, alert: "Couldn't save the image. Please try again.", status: :see_other
    end

    private

    def valid_image?(file)
      file.respond_to?(:content_type) &&
        file.content_type.to_s.start_with?("image/") &&
        file.respond_to?(:size) && file.size.to_i.positive? && file.size <= MAX_BYTES
    end
  end
end
