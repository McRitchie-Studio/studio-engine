# The role colours' save endpoints. The editor lives on the style guide
# (style/_theme), so GET /admin/theme sends an admin there; the route and its
# name stay, because hosts link and register them.
class ThemeSettingsController < ApplicationController
  before_action :require_admin

  def edit
    redirect_to editor_path
  end

  def update
    @theme_setting = ThemeSetting.find_or_initialize_by(app_name: Studio.app_name)

    rescue_and_log(target: @theme_setting) do
      @theme_setting.update!(theme_params)
      Rails.cache.delete("studio/theme/#{Studio.app_name}")
      done "Theme saved."
    end
  rescue StandardError => e
    return render(json: { error: e.message }, status: :unprocessable_entity) if request.format.json?

    redirect_to editor_path, alert: "Error saving theme: #{e.message}"
  end

  def regenerate
    Rails.cache.delete("studio/theme/#{Studio.app_name}")
    done "Theme cache cleared."
  end

  private

  def editor_path = admin_style_path(anchor: "theme")

  # The style guide saves by fetch and asks for JSON: a 204 is its proof of the
  # write. A form post is redirected back to the editor.
  def done(notice)
    return head(:no_content) if request.format.json?

    redirect_to editor_path, notice: notice
  end

  def theme_params
    params.require(:theme_setting).permit(:primary, :accent1, :accent2, :warning, :danger, :dark, :light)
  end
end
