# frozen_string_literal: true

require "erb"

# The engine's one line-icon set: Lucide, vendored under lib/studio/icons/lucide (see the
# README beside it for the license and how to add one). Pure Ruby, so the unit suite reads
# it without booting the dummy app. Views call StudioIconHelper#studio_icon.
#
# A NAME IS LOOKED UP, NEVER BUILT INTO A PATH. Only a name in the directory listing
# reaches File.read, so a host passing a bad name gets nil and cannot read another file.
module Studio
  module Icons
    DIR = File.expand_path("icons/lucide", __dir__)
    # Lucide draws at 2 on a 24 box. At 18px that reads heavy beside 13.5px text, so the
    # set renders thinner, as the sidebar's approved mockup did (2 x 18/24 is 1.5).
    STROKE_WIDTH = 1.6

    module_function

    def names
      @names ||= Dir.children(DIR).filter_map { |file| file.delete_suffix(".svg") if file.end_with?(".svg") }.sort.freeze
    end

    def known?(name)
      names.include?(name.to_s)
    end

    # The whole <svg>, or nil for a name the set does not hold. Decorative: the row or
    # button beside it carries the words.
    def svg(name, size: 18, css_class: nil)
      return nil unless known?(name)

      px = Integer(size)
      attributes = [
        %(xmlns="http://www.w3.org/2000/svg"),
        %(width="#{px}" height="#{px}"),
        %(viewBox="0 0 24 24"),
        %(fill="none" stroke="currentColor" stroke-width="#{STROKE_WIDTH}"),
        %(stroke-linecap="round" stroke-linejoin="round"),
        %(aria-hidden="true" focusable="false"),
        (%(class="#{ERB::Util.html_escape(css_class)}") if css_class.to_s != "")
      ].compact.join(" ")
      "<svg #{attributes}>#{shapes(name.to_s)}</svg>"
    end

    # The drawing inside the file's <svg>, read once per name.
    def shapes(name)
      @shapes ||= {}
      @shapes[name] ||= File.read(File.join(DIR, "#{name}.svg"))[%r{<svg[^>]*>(.*)</svg>}m, 1].to_s.gsub(/\s*\n\s*/, "").freeze
    end
  end
end
