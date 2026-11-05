# frozen_string_literal: true

require "uri"

# Resolves Studio.sidebar_sections — the host's declared link-sidebar data —
# for a given view context. Pure Ruby (no Rails dependency) so the unit suite
# exercises the resolution rules without booting the dummy app.
#
# Declared sections may be a static Array or a callable (receives the view
# context) for dynamic data: route helpers, logged_in? walls, model-backed
# link lists. Each section normalizes to symbol keys:
#
#   { title: "Site", admin: true, header: true, links: [
#     { label: "Dashboard", href: "/admin", emoji: "📊",
#       hover_emoji: "🔬", desc: "Users + logs", target: "_blank" } ] }
#
# Sections flagged admin: true resolve only for admin? viewers, so the
# trigger and panel stay invisible to everyone else even when the host
# declares nothing but admin links.
#
# A section's title is its group's accessible name. By default the panel shows no label
# word; a section with header: true also shows its title above its rows. A link's desc is
# optional and shows only on hover or keyboard focus.
#
# Under Studio.sidebar_style = :glass a link may also carry icon: "rocket", a Studio::Icons
# name: the row draws that line icon in place of its emoji, with no hover swap. The emoji
# stays the fallback for a name the set does not hold.
#
# THE ENGINE PREPENDS ONE SECTION OF ITS OWN — "You", linking to /profile. The
# engine ships that page, so it ships the way in rather than asking five apps to
# declare the same entry and watch them drift. See `standard` below for the two
# gates it carries.
module Studio
  module SidebarSections
    STYLES = %i[default glass].freeze

    module_function

    # The value Studio.sidebar_style= stores, or ArgumentError. A misspelt style would
    # otherwise draw the default panel with no word about why.
    def style!(value)
      style = value.respond_to?(:to_sym) ? value.to_sym : value
      return style if STYLES.include?(style)

      raise ArgumentError, "Studio.sidebar_style must be one of #{STYLES.join(', ')}, got #{value.inspect}"
    end

    # The href of the row for the page at `path`, or nil. One row at most: the longest
    # match wins, so /build/requests lights App Requests and not Build. A row also owns
    # the pages beneath it (/books/2026 lights Books). "/" only ever matches itself. An absolute href counts only on `host`, so a satellite's /docs
    # never lights here.
    def current_href(sections, path, host: nil)
      return nil if path.to_s.empty?

      here = path.to_s[/\A[^?#]*/].chomp("/")
      best = Array(sections).flat_map { |section| Array(section[:links]) }.filter_map do |link|
        target = link_path(link[:href], host)
        next if target.nil?
        next unless target == here || (!target.empty? && here.start_with?("#{target}/"))

        [target.length, link[:href]]
      end.max_by(&:first)
      best&.last
    end

    # An href's local path without its trailing slash, or nil when it leads elsewhere or
    # to nothing here (another host, a bare #anchor, a mailto:).
    def link_path(href, host)
      uri = URI.parse(href.to_s)
      return nil if uri.path.to_s.empty? || uri.opaque
      return nil if uri.host && uri.host != host

      uri.path.chomp("/")
    rescue URI::Error
      nil
    end

    def resolve(declared, view)
      sections = declared.respond_to?(:call) ? declared.call(view) : declared
      admin = view.respond_to?(:admin?) && view.admin?
      (standard(view) + Array(sections))
        .map { |section| symbolize(section) }
        .reject { |section| section[:admin] && !admin }
        .map { |section| section.merge(links: Array(section[:links]).map { |link| symbolize(link) }) }
    end

    # What the ENGINE puts in every app's sidebar, ahead of whatever the host
    # declared. The engine ships /profile, so it ships the way in — otherwise
    # every consumer writes the same entry and they drift in wording and emoji.
    #
    # PREPENDED, not appended: it is the viewer's own account, the thing nearest
    # to them, and the operator asked for it at the top.
    #
    # TWO GATES, and both are load-bearing:
    #
    #   * the route must be drawn. An app that set draw_profile_routes = false
    #     would otherwise be handed a menu item pointing at a route that does not
    #     exist — a 404 from its own navigation.
    #   * the viewer must be signed in. /profile requires authentication, so
    #     offering it to a signed-out visitor bounces them to the login page from
    #     something that looked like navigation. Same shape as the `admin:` rule
    #     below, which already drops sections a viewer may not see.
    #
    # A view that answers neither predicate (a bare context in a unit test) gets
    # nothing, which is the safe direction: a missing link is visible and
    # fixable, a link to nowhere is the bug.
    def standard(view)
      return [] unless profile_link?(view)

      [{ title: "You", links: [
        { label: "Profile", href: view.profile_path, emoji: "👤", icon: "user" }
      ] }]
    end

    def profile_link?(view)
      return false unless defined?(Studio) && Studio.respond_to?(:draw_profile_routes)
      return false unless Studio.draw_profile_routes
      return false unless view.respond_to?(:profile_path)
      return false unless view.respond_to?(:logged_in?) && view.logged_in?

      true
    end

    def symbolize(hash)
      hash.to_h.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
    end
  end
end
