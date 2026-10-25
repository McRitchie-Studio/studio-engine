# frozen_string_literal: true

# The navbar's view seams: links, items, the avatar badge and the signed-out
# CTA. Each resolves once per render pass, since a host lambda may read
# current_user or the database.
module StudioNavbarHelper
  NAVBAR_LINK_CLASS = "inline-flex items-center gap-1.5 whitespace-nowrap font-medium transition"
  NAVBAR_BADGE_CLASS = "rounded-full border border-subtle px-1.5 py-0.5 text-[10px] leading-none " \
                       "font-semibold text-muted tabular-nums"

  def studio_navbar_links
    @studio_navbar_links ||= Studio.navbar_links_for(self)
  end

  # The signed-out CTA ({ label:, path: }) or nil for the sign-in button.
  # Resolved once per render pass: the desktop button and the phone row's
  # sign-in link both ask, and a host callable may read the request.
  def studio_navbar_signed_out_cta
    return @studio_navbar_signed_out_cta if defined?(@studio_navbar_signed_out_cta)

    @studio_navbar_signed_out_cta = Studio.navbar_signed_out_cta_for(self)
  end

  # Studio.navbar_items as partial specs ({ partial:, locals: }), [] for none.
  # Resolved once per render pass: the desktop bar and the phone row both ask.
  def studio_navbar_items
    @studio_navbar_items ||= Studio.navbar_items_for(self)
  end

  # Studio.navbar_avatar_badge as one partial spec, or nil for no badge.
  def studio_navbar_avatar_badge
    return @studio_navbar_avatar_badge if defined?(@studio_navbar_avatar_badge)

    @studio_navbar_avatar_badge = Studio.navbar_avatar_badge_for(self)
  end

  # Studio.navbar_header_bars as partial specs, [] for none.
  def studio_navbar_header_bars
    @studio_navbar_header_bars ||= Studio.navbar_header_bars_for(self)
  end

  # Studio.navbar_menu_trigger as one partial spec, or nil for the admin
  # dropdown. Resolved once per render pass: the rail and the phone row both ask.
  def studio_navbar_menu_trigger
    return @studio_navbar_menu_trigger if defined?(@studio_navbar_menu_trigger)

    @studio_navbar_menu_trigger = Studio.navbar_menu_trigger_for(self)
  end

  # One resolved partial spec, rendered through the normal partial pipeline.
  def studio_navbar_slot_tag(spec)
    render partial: spec[:partial], locals: spec[:locals]
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
