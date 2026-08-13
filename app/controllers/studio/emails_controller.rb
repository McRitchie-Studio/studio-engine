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
    before_action :load_entry, only: %i[show raw update destroy settings copy logo]
    before_action :require_uploads, only: %i[update destroy logo]

    MAX_BYTES = 8.megabytes

    def index
      @entries = Studio::EmailCatalog.entries
      @uploads_available = Studio::EmailCatalog.uploads_available?

      # The list renders every banner and subject AS THEY WOULD ARRIVE, which has
      # no answer until someone is receiving them.
      @targets = Studio::EmailPreviewTarget.all
      @target = Studio::EmailPreviewTarget.resolve(params[:target])
      @preview_name = @target&.name
    end

    # GET /admin/emails/:key — one email: its banner, its type, and a live
    # preview built from the host's sample data.
    def show
      # nil for an ORPHAN — an email that left the registry while this app still
      # holds an upload for it. The view renders a minimal page whose only real
      # affordance is Revert, which is the whole reason the route stays open.
      @entry = Studio::EmailCatalog.entry(@key)
      @orphan = @entry.nil?
      return render(:orphan) if @orphan

      @subject = Studio::EmailCatalog.preview_subject(@key)
      @preview_error = Studio::EmailCatalog.preview_error(@key)
      @uploads_available = Studio::EmailCatalog.uploads_available?

      # WHO this is previewed as. The banner greets by name, so "what does this
      # email look like" has no answer until someone is receiving it — and the
      # two people who break email differently (an admin with a full name on
      # file, a member with none) are both offered.
      @targets = Studio::EmailPreviewTarget.all
      @target = Studio::EmailPreviewTarget.resolve(params[:target])
      @preview_name = @target&.name

      # The banner AS IT ARRIVES, built the same way a mailer builds it so the
      # page cannot show something the inbox never gets.
      @banner = Studio::Banner.for(@key, name: @preview_name)
      @subject = Studio::EmailCatalog.subject_for(@key, name: @preview_name) || @subject
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
        message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, WebP or GIF under 8 MB."
        return redirect_to admin_emails_path, alert: message, status: :see_other
      end

      rescue_and_log do
        Studio::EmailCatalog.store(@key, io: file, content_type: file.content_type)
        redirect_to admin_emails_path, notice: "#{Studio::EmailCatalog.label(@key)} banner updated.", status: :see_other
      end
    rescue StandardError
      redirect_to admin_emails_path, alert: "Couldn't save the image. Please try again.", status: :see_other
    end

    # PATCH /admin/emails/:key/settings — operator-tunable knobs.
    #
    # The scrim is the dial between a readable header and a visible picture, and
    # the right value depends on artwork that changes without a deploy. Blank
    # clears the override so the email falls back to the registry default rather
    # than being pinned to whatever that default was on the day.
    def settings
      percent = params[:scrim_percent]

      if percent.present? && !Studio::EmailSetting::SCRIM_RANGE.cover?(percent.to_i)
        return redirect_to admin_email_path(@key), status: :see_other,
                           alert: "Tint must be between 0 and 100."
      end

      rescue_and_log do
        Studio::EmailSetting.set_scrim(@key, percent)
        redirect_to admin_email_path(@key), status: :see_other,
                    notice: percent.present? ? "Tint set to #{percent.to_i}%." : "Tint reset to the default."
      end
    rescue StandardError
      redirect_to admin_email_path(@key), status: :see_other,
                  alert: "Couldn't save the tint. Please try again."
    end

    # PATCH /admin/emails/:key/copy — the banner's words and logo.
    #
    # Separate from #settings rather than one big form: the tint is a slider you
    # nudge while looking at the picture, the copy is a sentence you write. They
    # save independently so tuning one never risks clobbering an unsaved edit to
    # the other.
    # Saves EVERYTHING the page edits, in one write. The page has a single Save
    # button, so it must: three buttons that each saved a third of the form meant
    # an operator who changed the subject and the tint had to notice there were
    # two places to press.
    def copy
      rescue_and_log do
        attrs = copy_params
        Studio::EmailSetting.set_copy(@key, attrs)
        # The button's on/off is a boolean, so it is not a COPY_FIELD and needs
        # its own write — the same shape that once made hide_logo a dead control.
        Studio::EmailSetting.set_cta_enabled(@key, attrs[:cta_enabled]) if attrs.key?(:cta_enabled)
        # The footer is SHARED across every email, so it is stored under its own
        # key rather than this one, and the page posts its two inputs on every
        # save. update_footer (not set_footer) is what makes that safe: it writes
        # only on a real change, so blank posts from a page nobody edited cannot
        # wipe the footer every email sends.
        #
        # The form spells the footer's logo `footer_logo_url` because `logo_url`
        # is already this email's OWN banner logo; the model takes it as
        # `logo_url`, so the rename is undone here.
        Studio::EmailSetting.update_footer(discord_url: attrs[:discord_url],
                                           logo_url: attrs[:footer_logo_url])
        if params.key?(:scrim_percent)
          percent = params[:scrim_percent]
          percent = nil unless percent.present? && Studio::EmailSetting::SCRIM_RANGE.cover?(percent.to_i)
          Studio::EmailSetting.set_scrim(@key, percent)
        end
        redirect_to admin_email_path(@key), status: :see_other, notice: "Saved."
      end
    rescue StandardError
      redirect_to admin_email_path(@key), status: :see_other,
                  alert: "Couldn't save the banner text. Please try again."
    end

    # PATCH /admin/emails/:key/logo — upload a logo for THIS email, or drop it.
    #
    # Its own action and its own ImageCache purpose: a logo is a small transparent
    # mark, a banner is 3:1 artwork that may be animated, and reverting one must
    # not touch the other.
    def logo
      if params[:remove].present?
        rescue_and_log { Studio::EmailCatalog.revert_logo(@key) }
        return redirect_to admin_email_path(@key), status: :see_other,
                           notice: "Back to the standard logo."
      end

      file = params[:image]
      unless valid_image?(file)
        message = file.blank? ? "Choose an image to upload." : "Use a PNG, JPG, WebP or GIF under 8 MB."
        return redirect_to admin_email_path(@key), alert: message, status: :see_other
      end

      rescue_and_log do
        Studio::EmailCatalog.store_logo(@key, io: file, content_type: file.content_type)
        redirect_to admin_email_path(@key), notice: "Logo updated.", status: :see_other
      end
    rescue StandardError
      redirect_to admin_email_path(@key), alert: "Couldn't save the logo. Please try again.", status: :see_other
    end

    # DELETE /admin/emails/:key — drop this app's override and fall back to the
    # inherited default.
    def destroy
      # rescue_and_log, like #update: destroy is a WRITE path (it drops an
      # ImageCache row and deletes the S3 object behind it), and the bare rescue
      # below turns any failure into a friendly alert. Without the log that
      # failure is invisible — the admin sees "try again" and nothing reaches
      # ErrorLog to say why.
      rescue_and_log do
        reverted = Studio::EmailCatalog.revert(@key)
        # label() falls back to the humanised key, so an ORPHAN (no registry
        # entry at all) still gets a readable message rather than a blank one.
        label = Studio::EmailCatalog.label(@key).presence || @key.humanize
        notice = if reverted
                   "#{label} reverted to the inherited default."
                 else
                   "#{label} was already using the inherited default."
                 end
        redirect_to admin_emails_path, notice: notice, status: :see_other
      end
    rescue StandardError
      redirect_to admin_emails_path, alert: "Couldn't revert the image. Please try again.", status: :see_other
    end

    private

    # COPY_FIELDS plus :hide_logo, and the awkward shape is the honest one.
    #
    # This list was DERIVED from COPY_FIELDS precisely because a hand-typed one
    # dropped :subject — the form posted it, strong params filtered it out, and
    # the page still said "Saved." Deriving it then reintroduced exactly that bug
    # for the one editable column that is NOT a copy field: hide_logo is a
    # boolean rather than text, so it lives outside COPY_FIELDS and vanished from
    # the permit list. Hiding the logo saved nothing and reported success.
    #
    # Every model-level logo test passed throughout, because set_copy was never
    # the broken part. The filter lives here, so the assertion does too.
    def copy_params
      params.permit(*Studio::EmailSetting::COPY_FIELDS, :hide_logo, :cta_enabled,
                    :discord_url, :footer_logo_url)
            .to_h.symbolize_keys
    end

    # A key is reachable when it is REGISTERED, or when this app still holds an
    # upload for it.
    #
    # The second half matters because the standard set can change. An email that
    # leaves it takes its page with it — and a host that had uploaded its own
    # artwork was left with a live ImageCache row, a paid-for S3 object, and a
    # 404 on the only page that could delete either. Keeping the page reachable
    # for an orphan is what gives that operator a revert button.
    def load_entry
      @key = params[:key].to_s
      return if Studio::EmailCatalog.known?(@key)
      return if Studio::EmailCatalog.record(@key).present?

      head :not_found
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
