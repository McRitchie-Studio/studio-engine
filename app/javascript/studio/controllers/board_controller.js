// board: one board primitive (studio/board/_board), on the engine's Stimulus
// application, which reads data-studio-controller and registers this controller
// lazily, the first time a page renders a board. It sits on the element that
// carries the board's Alpine scope:
//
//   <section x-data="studioBoard({...})" data-studio-controller="board">
//
// The scope (studio/board) owns the state, the requests and the toasts. This
// controller owns what needs the page: it loads SortableJS, so only a page with
// a board fetches it, and wires the zones when both the library and the scope
// are there. Until it connects the board renders and its chrome works; a card
// does not drag, and the element carries no data-alpine-ready.
import { Controller } from "@hotwired/stimulus"
import { loadSortable, scopeFor } from "studio/board"

export default class extends Controller {
  connect() {
    const connection = this.connection = {}
    // A board whose SortableJS fails to load is wired without it: it still
    // counts, toasts and follows live updates.
    const sortable = loadSortable().catch((error) => {
      console.error("[studio] SortableJS failed to load; the board does not drag", error)
      return null
    })

    Promise.all([scopeFor(this.element), sortable]).then(([scope, Sortable]) => {
      if (this.connection !== connection) return
      connection.unwire = scope.wire(Sortable)
    })

  }

  disconnect() {
    this.unwire()
  }

  unwire() {
    const connection = this.connection
    this.connection = null
    if (connection && connection.unwire) connection.unwire()
  }
}
