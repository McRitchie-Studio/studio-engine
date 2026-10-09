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
// THREE WAYS A CONTROLLER REGISTERS. The every-page chrome (nav collapse, modal
// host, toast, link sidebar) is registered by studio/application, which imports
// it statically. The hold button is registered HERE, statically, because it
// confirms real actions (see below). A PAGE-SPECIFIC CONTROLLER is listed in
// LAZY below and registered by studio/lazy_controllers the first time an
// element names one.
//
// WHY THE HOLD BUTTON IS STATIC. A lazy controller is one more request, made
// when its element first appears: for the token modal, minutes after the page
// loaded. If that request fails once (a dropped connection, or a deploy that
// retired the digested file) the browser never fetches the module again in
// that document, and the button would render and take a press that does
// nothing. Imported here it arrives with the page, in the preloaded boot graph,
// and no later request stands between a press and its hold.
//
// WHY THIS IS ITS OWN ENTRY POINT. layouts/studio/_head imports this module by
// its own nonced module tag as well as through the boot graph. Its only imports
// are Stimulus, studio/lazy_controllers and the hold button's controller (which
// imports studio/hold_button and studio/hold_button_hooks), so a throw or a
// missing file elsewhere in studio/application's graph still leaves a page its
// hold button.
import { Application, defaultSchema } from "@hotwired/stimulus"
import { watchLazyControllers } from "studio/lazy_controllers"
import HoldButtonController from "studio/controllers/hold_button_controller"

export const schema = {
  ...defaultSchema,
  controllerAttribute: "data-studio-controller",
  actionAttribute: "data-studio-action",
  targetAttribute: "data-studio-target"
}

// identifier -> its controller module. Dynamic imports, so none of these joins
// the every-page boot graph (Studio::Engine.javascript_boot_graph). A control
// that must work whenever its page does is not listed here: a failed load is
// final for the document (studio/lazy_controllers).
export const LAZY = {
  "geo-settings": () => import("studio/controllers/geo_settings_controller"),
  "link-preview-card": () => import("studio/controllers/link_preview_card_controller")
}

export const application = Application.start(document.documentElement, schema)

application.register("hold-button", HoldButtonController)

export const lazy = watchLazyControllers({
  root: document.documentElement,
  attribute: schema.controllerAttribute,
  loaders: LAZY,
  register: (name, controller) => application.register(name, controller)
})
