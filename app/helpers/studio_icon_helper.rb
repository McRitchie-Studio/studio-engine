# studio_icon("rocket", size: 18): one line icon as inline SVG in currentColor, so it takes
# its color from the text around it and needs no asset request under a strict CSP. The set
# is Studio::Icons. An unknown name renders nothing (nil), so a caller can fall back:
#
#   studio_icon(link[:icon]) || link[:emoji]
module StudioIconHelper
  def studio_icon(name, size: 18, class: nil)
    Studio::Icons.svg(name, size: size, css_class: binding.local_variable_get(:class))&.html_safe
  end
end
