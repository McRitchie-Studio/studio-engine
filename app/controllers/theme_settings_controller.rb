class ThemeSettingsController < ApplicationController
  before_action :require_admin

  def edit
    @theme_setting = ThemeSetting.current
    @defaults = Studio.theme_config
    @preview_css = Studio::ThemeResolver.new(@theme_setting.resolved_colors).to_css
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

    @defaults = Studio.theme_config
    @preview_css = Studio::ThemeResolver.new(@theme_setting.resolved_colors).to_css
    flash.now[:alert] = "Error saving theme: #{e.message}"
    render :edit, status: :unprocessable_entity
  end

  def regenerate
    Rails.cache.delete("studio/theme/#{Studio.app_name}")
    done "Theme cache cleared."
  end

  private

  # The style guide saves by fetch and asks for JSON: a 204 is its proof of the
  # write. A form post is redirected back to the editor.
  def done(notice)
    return head(:no_content) if request.format.json?

    redirect_to admin_theme_path, notice: notice
  end

  def theme_params
    params.require(:theme_setting).permit(:primary, :accent1, :accent2, :warning, :danger, :dark, :light)
  end
end
