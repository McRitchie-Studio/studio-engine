# The engine's importmap pins, drawn into every host by the studio.importmap
# initializer (lib/studio/engine.rb) before the host's own config/importmap.rb.
#
# One `pin` per module under app/javascript/studio, named "studio/<name>", and
# none preloaded: a page fetches a module only when something imports it.
#
# `pin`, not `pin_all_from`, so a host can override one: importmap-rails expands
# a pin_all_from directory AFTER every plain pin, so a directory pin would beat
# the host's own `pin` of the same name. Plain pins are last-drawn-wins, and the
# host's map is drawn last.
Studio::Engine.javascript_module_logical_paths.each do |logical_path|
  pin logical_path.delete_suffix(".js"), to: logical_path, preload: false
end
