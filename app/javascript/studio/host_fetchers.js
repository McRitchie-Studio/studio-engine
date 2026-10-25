// studio/host_fetchers: the seam a host fills with its own request wrappers.
//
// The engine pins this name to this empty module. A host that sends its
// requests through a wrapper of its own (Turf Monster's authedFetch) pins the
// same name to a file of its own, which wins because the host's importmap is
// drawn last, and exports the wrapper by name:
//
//   # config/importmap.rb
//   pin "studio/host_fetchers", to: "newsletter_fetchers.js"
//   // app/javascript/newsletter_fetchers.js
//   export { authedFetch } from "solana_utils"
//
// A partial that takes a fetcher: local (studio/profiles/_newsletter_modals)
// names one of those exports; studio/newsletter_modal imports this module on
// the first press that needs it. Nothing here is on the boot graph.
export {}
