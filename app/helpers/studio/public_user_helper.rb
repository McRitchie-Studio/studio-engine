# frozen_string_literal: true

module Studio
  # Links to the public user page (/u/:username). Clicking a username anywhere
  # in a Studio app should land here, so every app reaches it the same way:
  #
  #   <%= link_to_user_profile(entry.user) %>                  # text: display_name
  #   <%= link_to_user_profile(user, "@#{user.username}", class: "font-semibold") %>
  #   <%= link_to_user_profile(user) do %> ...avatar... <% end %>
  #   studio_user_profile_path(user)   # => "/u/alex", or nil
  #
  # The path helpers answer nil, and link_to_user_profile renders its text in a
  # plain <span> with no link, whenever there is no page to go to: the app has
  # not drawn the route (Studio.draw_public_user_routes), or the user has no
  # username. So a view can call them for every user without asking first.
  #
  # Prefixed names for the reason Studio::GeoHelper gives: every helper module is
  # included into every view. The ROUTE helper is studio_public_user_path; these
  # take a user rather than a username, which is why they are named apart.
  module PublicUserHelper
    def studio_user_profile_path(user, **options)
      studio_user_profile_location(:path, user, options)
    end

    def studio_user_profile_url(user, **options)
      studio_user_profile_location(:url, user, options)
    end

    def link_to_user_profile(user, name = nil, html_options = nil, **options, &block)
      html_options, name = name, nil if name.is_a?(Hash)
      html_options = (html_options || {}).merge(options)
      path = studio_user_profile_path(user)

      content = block ? capture(&block) : (name || studio_user_profile_label(user))
      if path
        html_options[:data] = { public_user_link: "" }.merge(html_options[:data] || {})
        link_to(content, path, html_options)
      else
        content_tag(:span, content, html_options)
      end
    end

    private

    def studio_user_profile_location(kind, user, options)
      return nil unless respond_to?(:"studio_public_user_#{kind}")

      username = Studio::PublicUser.username_for(user)
      return nil if username.nil?

      public_send(:"studio_public_user_#{kind}", username: username, **options)
    end

    def studio_user_profile_label(user)
      return user.to_s if user.is_a?(String) || user.is_a?(Symbol)

      label = user.display_name if user.respond_to?(:display_name)
      label.presence || Studio::PublicUser.username_for(user).to_s
    end
  end
end
