// studio/application: the engine's browser boot, imported on every page by
// layouts/studio/_head (javascript_import_module_tag, which carries the
// request's CSP nonce).
//
// The Stimulus application itself, its attribute schema, the hold button and
// the lazily registered page-specific controllers are studio/stimulus. This
// file registers the every-page chrome on it.
//
// Everything this file imports statically is preloaded on every page
// (Studio::Engine.javascript_boot_graph), so the boot costs one round trip.
import { application, schema } from "studio/stimulus"
import NavCollapseController from "studio/controllers/nav_collapse_controller"
import ModalHostController from "studio/controllers/modal_host_controller"
import ToastController from "studio/controllers/toast_controller"
import LinkSidebarController from "studio/controllers/link_sidebar_controller"
import { startPinnedStack } from "studio/pinned_stack"
import { installAlpineShims } from "studio/alpine_shims"

installAlpineShims()
startPinnedStack()

application.register("nav-collapse", NavCollapseController)
application.register("modal-host", ModalHostController)
application.register("toast", ToastController)
application.register("link-sidebar", LinkSidebarController)

export { application, schema }
