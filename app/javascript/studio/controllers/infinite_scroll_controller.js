// infinite-scroll: the next page of a list loads as its end comes near, on the
// engine's Stimulus application (studio/stimulus registers it lazily). It sits
// on studio_infinite_scroll's wrapper. The behaviour is studio/infinite_scroll.
// If this controller fails to load, "Load more" is still a working link.
import { Controller } from "@hotwired/stimulus"
import { watchInfiniteScroll } from "studio/infinite_scroll"

export default class extends Controller {
  connect() {
    this.stop = watchInfiniteScroll(this.element, window)
  }

  disconnect() {
    if (this.stop) this.stop()
    this.stop = null
  }
}
