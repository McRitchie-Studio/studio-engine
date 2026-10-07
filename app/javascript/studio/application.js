// studio/application: the engine's browser boot, imported on every page by
// layouts/studio/_head (javascript_import_module_tag, which carries the
// request's CSP nonce).
//
// The engine runs its own Stimulus application, so its controllers are
// namespaced `studio--<name>` and never collide with a host's. "@hotwired/stimulus"
// resolves to the engine's vendored copy unless the host pins its own.
//
// Everything this file imports statically is preloaded on every page
// (Studio::Engine.javascript_boot_graph), so the boot costs one round trip.
import { Application } from "@hotwired/stimulus"
import NavCollapseController from "studio/controllers/nav_collapse_controller"
import { startPinnedStack } from "studio/pinned_stack"
import { installAlpineShims } from "studio/alpine_shims"

installAlpineShims()
startPinnedStack()

const application = Application.start()
application.register("studio--nav-collapse", NavCollapseController)

export { application }
