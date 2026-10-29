module StudioThemeHelper
  def studio_theme_css_tag
    css = Rails.cache.fetch("studio/theme/#{Studio.app_name}", expires_in: 1.hour) do
      colors = begin
        ThemeSetting.current.resolved_colors
      rescue ActiveRecord::StatementInvalid
        # Table doesn't exist yet (pre-migration) — use config defaults
        Studio.theme_config
      end
      Studio::ThemeResolver.new(colors).to_css
    end

    tag.style("#{css}\n#{Studio::TypeScale.css}\n#{Studio::UiPrimitives.css}".html_safe, nonce: content_security_policy_nonce)
  end
end
