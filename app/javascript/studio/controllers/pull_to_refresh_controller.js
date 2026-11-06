// pull-to-refresh: pull the page down from its top to reload it, on phones with
// touch only (studio/pull_to_refresh decides). On the engine's Stimulus
// application (studio/stimulus registers it lazily); it sits on
// studio_pull_to_refresh's wrapper. If it fails to load, nothing on the page
// depends on it: the browser's own reload still works.
import { Controller } from "@hotwired/stimulus"
import { watchPullToRefresh } from "studio/pull_to_refresh"

export default class extends Controller {
  connect() {
    this.stop = watchPullToRefresh(this.element, window, document)
  }

  disconnect() {
    if (this.stop) this.stop()
    this.stop = null
  }
}
