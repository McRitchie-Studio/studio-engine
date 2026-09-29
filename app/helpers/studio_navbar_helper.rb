# frozen_string_literal: true

# The navbar-links view seam. Links resolve once per render pass, since the
# host lambda may read current_user or the database.
module StudioNavbarHelper
  NAVBAR_LINK_CLASS = "inline-flex items-center gap-1.5 whitespace-nowrap font-medium transition"
  NAVBAR_BADGE_CLASS = "rounded-full border border-subtle px-1.5 py-0.5 text-[10px] leading-none " \
                       "font-semibold text-muted tabular-nums"

  def studio_navbar_links
    @studio_navbar_links ||= Studio.navbar_links_for(self)
  end

  # One resolved link. size is the text utility: text-sm on desktop, text-xs
  # in the phone row, matching the links apps hand-wrote in forked navbars.
  def studio_navbar_link_tag(link, size:)
    tone = link[:active] ? "text-primary" : "text-secondary hover:text-primary"
    link_to link[:href], class: "#{NAVBAR_LINK_CLASS} #{size} #{tone}",
                         aria: { current: ("page" if link[:active]) } do
      badge = content_tag(:span, link[:badge], class: NAVBAR_BADGE_CLASS) if link[:badge]
      safe_join([link[:label], badge].compact)
    end
  end
end
