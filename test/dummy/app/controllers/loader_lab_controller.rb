# The loader family's lab pages (docs/LOADER.md, "The family"), for the browser
# lane and for a local look:
#
#   /lab/loaders            the style guide's own Loaders section (style/_loaders),
#                           with its live infinite scroll fed by /lab/loaders_feed
#   /lab/loaders_feed       one page of that feed (style/_loaders_feed_page), the
#                           same partial StyleController#loaders_feed renders;
#                           ?ms= answers late (capped at 2s) so the busy state shows
#   /lab/pull_to_refresh    studio_pull_to_refresh around a page that stamps each
#                           render, so a spec can see the refresh happen
#
# Separate from E2eLabController, whose rule it keeps: a page sets up the
# partial's locals and nothing else. Turbo is on (survey_turbo_lab), as in every
# host, because infinite scroll and pull to refresh both ride it. ?turbo=0 drops
# it, for the no-script path of "Load more"; ?surface=glass needs that layout too.
class LoaderLabController < ActionController::Base
  helper E2eLabController::AssetDelivery

  def loaders = render(:loaders, layout: lab_layout)

  def loaders_feed
    sleep(params[:ms].to_i.clamp(0, 2000) / 1000.0)
    @page = params[:page].to_i.clamp(1, Studio::Loader::DEMO_FEED_PAGES)
    render(:loaders_feed, layout: lab_layout)
  end

  def pull_to_refresh
    @stamp = (Time.now.to_f * 1000).to_i
    render(:pull_to_refresh, layout: lab_layout)
  end

  private

  def lab_layout = (params[:turbo] == "0" || params[:surface].present?) ? "e2e_lab" : "survey_turbo_lab"
end
