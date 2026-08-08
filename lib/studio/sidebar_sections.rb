# frozen_string_literal: true

# Resolves Studio.sidebar_sections — the host's declared link-sidebar data —
# for a given view context. Pure Ruby (no Rails dependency) so the unit suite
# exercises the resolution rules without booting the dummy app.
#
# Declared sections may be a static Array or a callable (receives the view
# context) for dynamic data: route helpers, logged_in? walls, model-backed
# link lists. Each section normalizes to symbol keys:
#
#   { title: "Site", admin: true, links: [
#     { label: "Dashboard", href: "/admin", emoji: "📊",
#       hover_emoji: "🔬", desc: "Users + logs", target: "_blank" } ] }
#
# Sections flagged admin: true resolve only for admin? viewers, so the
# trigger and panel stay invisible to everyone else even when the host
# declares nothing but admin links.
module Studio
  module SidebarSections
    module_function

    def resolve(declared, view)
      sections = declared.respond_to?(:call) ? declared.call(view) : declared
      admin = view.respond_to?(:admin?) && view.admin?
      Array(sections).map { |section| symbolize(section) }
                     .reject { |section| section[:admin] && !admin }
                     .map { |section| section.merge(links: Array(section[:links]).map { |link| symbolize(link) }) }
    end

    def symbolize(hash)
      hash.to_h.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
    end
  end
end
