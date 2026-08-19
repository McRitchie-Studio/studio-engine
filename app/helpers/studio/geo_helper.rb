# frozen_string_literal: true

module Studio
  # View-side geo: the flag art and the words. The decisions all live in
  # Studio::Geo — this is the thin layer that turns a code into something a page
  # can render, and it is where the asset lookup lives because only a view knows
  # about the asset pipeline.
  #
  # Method names are `geo_`-prefixed on purpose. Rails includes every helper
  # module into every view, so an unprefixed `country_flag_emoji` here would
  # collide with a host app's own helper of that name during the window between
  # this gem release and that app deleting its copy — and the collision resolves
  # silently, by include order, to whichever was loaded last.
  module GeoHelper
    # Subdivision flags ship WITH the gem (app/assets/images/state-flags) so an
    # app gets the complete badge from an empty repository. Only the US set is
    # shipped today; every other country renders the emoji flag instead, which
    # needs no bytes at all.
    FLAG_ASSET_DIR = File.expand_path("../../assets/images/state-flags", __dir__)

    def geo_country_flag_emoji(alpha2)
      Studio::Geo.country_flag_emoji(alpha2)
    end

    def geo_foreign?(country)
      Studio::Geo.foreign?(country, home_country: Studio.geo_home_country)
    end

    def geo_subdivision_name(code, country: Studio.geo_home_country)
      Studio::Geo.subdivision_name(code, country: country)
    end

    # The asset path for a subdivision's flag, or nil when the gem ships no art
    # for it. Nil is a normal answer, not an error: the badge renders the code
    # text-only, which is exactly what a country outside the shipped set gets.
    #
    # Guarded on the COUNTRY as well as the code, and that guard is the important
    # one: the lookup matches a bare two-letter code, so an Italian region
    # normalising to "CA" would otherwise be handed the CALIFORNIA flag — a wrong
    # answer that looks right.
    def geo_subdivision_flag_path(code, country: Studio.geo_home_country)
      return nil if Studio::Geo.foreign?(country, home_country: Studio.geo_home_country)

      subdivision = Studio::Geo.normalize_subdivision(code)
      return nil if subdivision.nil?

      file = "#{subdivision.downcase}.svg"
      return nil unless File.exist?(File.join(FLAG_ASSET_DIR, file))

      image_path("state-flags/#{file}")
    end
  end
end
