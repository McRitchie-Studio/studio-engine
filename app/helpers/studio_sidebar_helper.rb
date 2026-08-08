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
  def studio_sidebar_replaces_admin_menu?
    studio_sidebar_sections.any? { |section| section[:admin] }
  end
end
