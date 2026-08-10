module Studio
  # /admin/emails — the standard transactional-email page every Studio app gets,
  # modelled on the living style guide (/admin/style): a plain host-inherited
  # controller whose view is a bare content wrapper, so it renders inside each
  # host's application layout and picks up that app's navbar and theme.
  #
  # It lists Studio::EmailImage's registry — one row per registered email, each
  # showing its live banner and whether that banner is the INHERITED engine
  # default or an APP-OWNED override — and writes an override through the shared
  # crop modal. Replaces /admin/email_images, which now redirects here.
  #
  # An app whose host never set Studio.s3_bucket_prefix cannot store an override.
  # That is a read-only page, not an error: uploads_available? gates the write
  # actions and the view explains why, so the page still shows what each email
  # is currently sending.
  class EmailsController < ApplicationController
    before_action :require_admin
    before_action :load_entry, only: %i[update destroy]
    before_action :require_uploads, only: %i[update destroy]

    MAX_BYTES = 8.megabytes

    def index
      @entries = Studio::EmailImage.entries
      @uploads_available = Studio::EmailImage.uploads_available?
    end

    # PATCH /admin/emails/:key — upload/replace this app's own banner.
    def update
      file = params[:image]
      unless valid_image?(file)
        message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, or WebP under 8 MB."
        return redirect_to admin_emails_path, alert: message, status: :see_other
      end

      rescue_and_log do
        Studio::EmailImage.store(@key, io: file, content_type: file.content_type)
        redirect_to admin_emails_path, notice: "#{Studio::EmailImage.label(@key)} banner updated.", status: :see_other
      end
    rescue StandardError
      redirect_to admin_emails_path, alert: "Couldn't save the image. Please try again.", status: :see_other
    end

    # DELETE /admin/emails/:key — drop this app's override and fall back to the
    # inherited default.
    def destroy
      reverted = Studio::EmailImage.revert(@key)
      notice = if reverted
                 "#{Studio::EmailImage.label(@key)} reverted to the inherited default."
               else
                 "#{Studio::EmailImage.label(@key)} was already using the inherited default."
               end
      redirect_to admin_emails_path, notice: notice, status: :see_other
    rescue StandardError
      redirect_to admin_emails_path, alert: "Couldn't revert the image. Please try again.", status: :see_other
    end

    private

    def load_entry
      @key = params[:key].to_s
      head :not_found unless Studio::EmailImage.known?(@key)
    end

    def require_uploads
      return if Studio::EmailImage.uploads_available?

      redirect_to admin_emails_path, status: :see_other,
                  alert: "This app has no object storage configured, so email images can't be changed here yet."
    end

    def valid_image?(file)
      file.respond_to?(:content_type) &&
        file.content_type.to_s.start_with?("image/") &&
        file.respond_to?(:size) && file.size.to_i.positive? && file.size <= MAX_BYTES
    end
  end
end
