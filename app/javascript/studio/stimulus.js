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
// A page that must find its controller connected the moment it has loaded
// registers it from its own module tag instead (studio/style_guide, for the
// style guide's Modals section): the tag runs with the page, in document order.
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
// final for the document (studio/lazy_controllers). The board is listed: a
// board whose controller failed still renders, counts and toasts, and says that
// its cards do not drag (data-studio-controller-failed="board"). So is the
// knowledge transcript: a recording whose controller failed still plays from
// its own controls, and its page says that click-to-play did not load. So is the
// agent chat: a chat whose controller failed still renders, and its section
// carries data-studio-controller-failed="agent-chat". So is the voice row: a
// row whose controller failed keeps its saved state and its Delete, and says
// that recording did not load (data-studio-controller-failed="voice-profile").
// So are the voice capture pair (docs/VOICE_CAPTURE.md): a chip whose controller
// failed still shows its prompt line, and a recorder whose controller failed
// says recording did not load (data-studio-controller-failed="voice-recorder").
// So is the chat's mic: a mic whose controller failed says voice did not load,
// and the box still types (data-studio-controller-failed="agent-chat-voice").
// So is copy-text: a colour whose controller failed still shows its hex to select.
// So is the page header: its tabs are links, and a row whose controller failed
// keeps its bar at all times (data-studio-controller-failed="page-header").
// So is infinite scroll: a list whose controller failed keeps its "Load more"
// link, which loads the next page by itself. So is pull to refresh: nothing
// depends on it, and the browser's own reload still works.
export const LAZY = {
  "board": () => import("studio/controllers/board_controller"),
  "geo-settings": () => import("studio/controllers/geo_settings_controller"),
  "link-preview-card": () => import("studio/controllers/link_preview_card_controller"),
  "email-banner-scale": () => import("studio/controllers/email_banner_scale_controller"),
  "booking": () => import("studio/controllers/booking_controller"),
  "footer-map": () => import("studio/controllers/footer_map_controller"),
  "survey": () => import("studio/controllers/survey_controller"),
  "knowledge-transcript": () => import("studio/controllers/knowledge_transcript_controller"),
  "agent-chat": () => import("studio/controllers/agent_chat_controller"),
  "agent-chat-voice": () => import("studio/controllers/agent_chat_voice_controller"),
  "voice-profile": () => import("studio/controllers/voice_profile_controller"),
  "microphone-chip": () => import("studio/controllers/microphone_chip_controller"),
  "voice-recorder": () => import("studio/controllers/voice_recorder_controller"),
  "copy-text": () => import("studio/controllers/copy_text_controller"),
  "page-header": () => import("studio/controllers/page_header_controller"),
  "infinite-scroll": () => import("studio/controllers/infinite_scroll_controller"),
  "pull-to-refresh": () => import("studio/controllers/pull_to_refresh_controller")
}

export const application = Application.start(document.documentElement, schema)

application.register("hold-button", HoldButtonController)

export const lazy = watchLazyControllers({
  root: document.documentElement,
  attribute: schema.controllerAttribute,
  loaders: LAZY,
  register: (name, controller) => application.register(name, controller)
})
