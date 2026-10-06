# The engine's importmap pins, drawn into every host by the studio.importmap
# initializer (lib/studio/engine.rb) before the host's own config/importmap.rb.
# Each module under app/javascript/studio is pinned as "studio/<name>" and is not
# preloaded: a page fetches it only when something imports it.
pin_all_from Studio::Engine.root.join("app/javascript/studio"), under: "studio", to: "studio", preload: false
