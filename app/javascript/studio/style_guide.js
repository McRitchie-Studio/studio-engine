// studio/style_guide: the living style guide's own controllers, registered on
// the engine's Stimulus application. style/_modals loads this module by its
// own nonced module tag, so only the style guide fetches it and it stays out of
// the every-page boot graph.
//
// A module tag and not an entry in studio/stimulus's LAZY table: the tag runs
// with the page, in document order, so the section's controller is connected
// by the time the document has loaded, and a script or a spec that drives the
// demos the moment the page is up finds them there.
import { application } from "studio/stimulus"
import StyleModalsController from "studio/controllers/style_modals_controller"

application.register("style-modals", StyleModalsController)
