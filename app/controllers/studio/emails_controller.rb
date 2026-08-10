module Studio
  # /admin/emails — the standard transactional-email page every Studio app gets,
  # modelled on the living style guide (/admin/style): a plain host-inherited
  # controller whose view is a bare content wrapper, so it renders inside each
  # host's application layout and picks up that app's navbar and theme.
  #
  # It lists Studio::EmailCatalog's registry — one row per registered email, each
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
    before_action :load_entry, only: %i[show raw update destroy]
    before_action :require_uploads, only: %i[update destroy]

    MAX_BYTES = 8.megabytes

    def index
      @entries = Studio::EmailCatalog.entries
      @uploads_available = Studio::EmailCatalog.uploads_available?
    end

    # GET /admin/emails/:key — one email: its banner, its type, and a live
    # preview built from the host's sample data.
    def show
      @entry = Studio::EmailCatalog.entry(@key)
      @subject = Studio::EmailCatalog.preview_subject(@key)
      @preview_error = Studio::EmailCatalog.preview_error(@key)
      @uploads_available = Studio::EmailCatalog.uploads_available?
    end

    # GET /admin/emails/:key/raw — the rendered email itself, as the iframe
    # source on #show. Layout-less on purpose: this response IS the email.
    #
    # A preview builder is host code run against whatever sample data this
    # environment happens to hold, so it is expected to fail sometimes. It
    # renders the failure as a readable page inside the iframe rather than
    # 500ing, so one broken builder costs one preview, not the manager.
    def raw
      html = Studio::EmailCatalog.preview_html(@key)
      return render(html: preview_unavailable_html.html_safe, layout: false) if html.nil?

      render html: html.html_safe, layout: false
    end

    # PATCH /admin/emails/:key — upload/replace this app's own banner.
    def update
      file = params[:image]
      unless valid_image?(file)
        message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, or WebP under 8 MB."
        return redirect_to admin_emails_path, alert: message, status: :see_other
      end

      rescue_and_log do
        Studio::EmailCatalog.store(@key, io: file, content_type: file.content_type)
        redirect_to admin_emails_path, notice: "#{Studio::EmailCatalog.label(@key)} banner updated.", status: :see_other
      end
    rescue StandardError
      redirect_to admin_emails_path, alert: "Couldn't save the image. Please try again.", status: :see_other
    end

    # DELETE /admin/emails/:key — drop this app's override and fall back to the
    # inherited default.
    def destroy
      reverted = Studio::EmailCatalog.revert(@key)
      notice = if reverted
                 "#{Studio::EmailCatalog.label(@key)} reverted to the inherited default."
               else
                 "#{Studio::EmailCatalog.label(@key)} was already using the inherited default."
               end
      redirect_to admin_emails_path, notice: notice, status: :see_other
    rescue StandardError
      redirect_to admin_emails_path, alert: "Couldn't revert the image. Please try again.", status: :see_other
    end

    private

    def load_entry
      @key = params[:key].to_s
      head :not_found unless Studio::EmailCatalog.known?(@key)
    end

    def require_uploads
      return if Studio::EmailCatalog.uploads_available?

      redirect_to admin_emails_path, status: :see_other,
                  alert: "This app has no object storage configured, so email images can't be changed here yet."
    end

    # Shown INSIDE the preview iframe when the builder is missing or raised.
    # Deliberately plain inline HTML: the iframe is its own document and does not
    # inherit the host app's stylesheet.
    def preview_unavailable_html
      reason = Studio::EmailCatalog.preview_error(@key)
      message = if reason
                  "This email's preview builder raised:<br><code style=\"color:#b91c1c\">" \
                    "#{ERB::Util.html_escape(reason)}</code>"
                else
                  "No preview is registered for this email. Add a <code>preview:</code> " \
                    "callable when registering it to see it rendered here."
                end

      <<~HTML
        <!doctype html>
        <html><body style="margin:0;padding:32px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#334155;background:#f8fafc;">
          <p style="font-size:14px;line-height:1.6;max-width:52ch;">#{message}</p>
        </body></html>
      HTML
    end

    def valid_image?(file)
      file.respond_to?(:content_type) &&
        file.content_type.to_s.start_with?("image/") &&
        file.respond_to?(:size) && file.size.to_i.positive? && file.size <= MAX_BYTES
    end
  end
end
