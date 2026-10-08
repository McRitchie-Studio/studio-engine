// studio/application: the engine's browser boot, imported on every page by
// layouts/studio/_head (javascript_import_module_tag, which carries the
// request's CSP nonce).
//
// The engine runs its own Stimulus application on its OWN attributes:
//
//   data-studio-controller="nav-collapse"   data-studio-action   data-studio-target
//
// so a host's Stimulus application never sees an engine controller. That is not
// tidiness: stimulus-loading's lazy loader (cyvasse) imports
// "controllers/<identifier>_controller" for every data-controller it meets, and
// would log "Failed to autoload controller" for each engine element. Values and
// classes keep Stimulus' own naming (data-nav-collapse-scrolled-class).
// "@hotwired/stimulus" resolves to the engine's vendored copy unless the host
// pins its own.
//
// Everything this file imports statically is preloaded on every page
// (Studio::Engine.javascript_boot_graph), so the boot costs one round trip.
import { Application, defaultSchema } from "@hotwired/stimulus"
import NavCollapseController from "studio/controllers/nav_collapse_controller"
import ModalHostController from "studio/controllers/modal_host_controller"
import { startPinnedStack } from "studio/pinned_stack"
import { installAlpineShims } from "studio/alpine_shims"

installAlpineShims()
startPinnedStack()

export const schema = {
  ...defaultSchema,
  controllerAttribute: "data-studio-controller",
  actionAttribute: "data-studio-action",
  targetAttribute: "data-studio-target"
}

const application = Application.start(document.documentElement, schema)
application.register("nav-collapse", NavCollapseController)
application.register("modal-host", ModalHostController)

export { application }
