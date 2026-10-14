# The link-sidebar's view seam. Exposed to host views automatically (the
# engine is non-isolated), so the navbar and any host layout can gate on
# studio_sidebar? without wiring. Sections resolve once per render pass —
# the resolver may call a host lambda that walks models or routes.
module StudioSidebarHelper
  def studio_sidebar_sections
    @studio_sidebar_sections ||= Studio.sidebar_sections_for(self)
  end

  def studio_sidebar?
    studio_sidebar_sections.any?
  end

  # The admin dropdown and the sidebar trigger share the cog glyph — showing
  # both reads as a double gear. When the viewer's resolved sections carry an
  # admin-flagged entry, the sidebar IS the admin menu (its title says so) and
  # the engine components skip the dropdown. Declaring only public sections
  # keeps the dropdown, so admins never lose Theme/Navbar/Error Logs.
  # The navbar's name and avatar open the sidebar wherever it renders: the
  # sidebar heads with the profile, so it is where the account control leads
  # (components/_user_nav). A host may define its own to say otherwise.
  def studio_account_opens_sidebar?
    studio_sidebar?
  end

  def studio_sidebar_replaces_admin_menu?
    studio_sidebar_sections.any? { |section| section[:admin] }
  end
end
