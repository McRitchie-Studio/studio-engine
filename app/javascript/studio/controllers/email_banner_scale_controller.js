// email-banner-scale: fits every email banner preview on the page to its frame,
// on the engine's Stimulus application (studio/stimulus, which reads
// data-studio-controller and registers this controller lazily). It sits on the
// anchor studio/emails/_banner_scale renders, once per page:
//
//   <template data-studio-controller="email-banner-scale"></template>
//
// The fit is studio/email_banner_scale. Connecting again after a Turbo visit
// fits the new body's previews; disconnecting drops the observer.
import { Controller } from "@hotwired/stimulus"
import { startBannerScale } from "studio/email_banner_scale"

export default class extends Controller {
  connect() {
    this.stop = startBannerScale(document, window.ResizeObserver)
  }

  disconnect() {
    if (this.stop) this.stop()
    this.stop = null
  }
}
