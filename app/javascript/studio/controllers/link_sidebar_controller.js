// link-sidebar: the link sidebar's presence on the page, on the engine's
// Stimulus application (studio/application, which reads data-studio-controller).
// It sits on the anchor components/_link_sidebar renders beside its panels:
//
//   <template data-studio-controller="link-sidebar"></template>
//
// The open flag and the document handlers are studio/link_sidebar, which
// registers $store.sidebars.linkTreeOpen on alpine:init and before a Turbo
// render. connect() registers it too, for a sidebar that arrived any other way.
// Registered by studio/application.
import { Controller } from "@hotwired/stimulus"
import { ensureLinkSidebarStore } from "studio/link_sidebar"

export default class extends Controller {
  connect() {
    ensureLinkSidebarStore(window.Alpine)
  }
}
