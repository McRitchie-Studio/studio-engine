# frozen_string_literal: true

module Studio
  # The crumb trail for studio/_page_header, from the app's parent map (Studio::Crumbs,
  # docs/PAGE_HEADER.md). Prefixed for the reason Studio::GeoHelper gives: every helper
  # module is included into every view.
  #
  #   studio_crumbs(:deployments)                 the map's own page: its ancestors
  #   studio_crumbs(parent: :deployments)         a page not in the map: its parent and up
  #   studio_crumbs(:release, release: @release)  keywords for the map's lambdas
  #   studio_crumbs_here                          an engine page: the map's page at this address
  #
  # A key the map lacks raises in development and test, and in production logs and
  # draws no trail (Studio::Crumbs.strict?), so a typo is not a 500.
  module CrumbsHelper
    def studio_crumbs(key = nil, parent: nil, **locals)
      Studio.crumbs.trail(self, key, parent: parent, **locals)
    rescue Studio::Crumbs::UnknownPage, Studio::Crumbs::Cycle => error
      raise if Studio::Crumbs.strict?

      Studio::Crumbs.report(error)
      []
    end

    # The trail for the page at this request's address, from the host's map, or none. An
    # engine page cannot know the host's key for itself, so it asks by address.
    def studio_crumbs_here
      return [] unless respond_to?(:request) && request

      key = Studio.crumbs.key_for_path(self, request.path)
      key ? studio_crumbs(key) : []
    end
  end
end
