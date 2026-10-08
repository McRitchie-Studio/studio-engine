// studio/stimulus: the engine's Stimulus application and its lazy controllers.
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
// EVERY-PAGE CONTROLLERS are registered by studio/application, which imports
// them statically. PAGE-SPECIFIC CONTROLLERS are listed in LAZY below and
// registered by studio/lazy_controllers the first time an element names one.
//
// WHY THIS IS ITS OWN ENTRY POINT. layouts/studio/_head imports this module by
// its own nonced module tag as well as through the boot graph. Its only imports
// are Stimulus and studio/lazy_controllers, so a throw or a missing file
// elsewhere in studio/application's graph still leaves a page its lazy
// controllers: the hold button confirms real actions.
import { Application, defaultSchema } from "@hotwired/stimulus"
import { watchLazyControllers } from "studio/lazy_controllers"

export const schema = {
  ...defaultSchema,
  controllerAttribute: "data-studio-controller",
  actionAttribute: "data-studio-action",
  targetAttribute: "data-studio-target"
}

// identifier -> its controller module. Dynamic imports, so none of these joins
// the every-page boot graph (Studio::Engine.javascript_boot_graph).
export const LAZY = {
  "hold-button": () => import("studio/controllers/hold_button_controller"),
  "board": () => import("studio/controllers/board_controller")
}

export const application = Application.start(document.documentElement, schema)

export const lazy = watchLazyControllers({
  root: document.documentElement,
  attribute: schema.controllerAttribute,
  loaders: LAZY,
  register: (name, controller) => application.register(name, controller)
})
