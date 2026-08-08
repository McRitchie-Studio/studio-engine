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
end
