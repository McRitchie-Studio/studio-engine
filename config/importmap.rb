# The engine's importmap pins, drawn into every host by the studio.importmap
# initializer (lib/studio/engine.rb) before the host's own config/importmap.rb.
#
# One `pin` per module under app/javascript/studio, named "studio/<name>". Only
# the boot graph is preloaded (Studio::Engine.javascript_boot_graph: the modules
# studio/application imports, which every page runs); any other module is
# fetched only when something imports it.
#
# A vendored library (studio/vendor/) is pinned under its package name only:
# "@hotwired/stimulus" is the engine's Stimulus. A host that pins its own
# (stimulus-rails) wins, and the engine's controllers run on that copy.
#
# The vendored SortableJS is pinned the same way, as "sortablejs", and never
# preloaded: studio/board imports it dynamically, on a page that drags. The file
# is the classic build (app/assets/javascripts/studio/sortable.js), which assigns
# window.Sortable when it is imported.
#
# `pin`, not `pin_all_from`, so a host can override one: importmap-rails expands
# a pin_all_from directory AFTER every plain pin, so a directory pin would beat
# the host's own `pin` of the same name. Plain pins are last-drawn-wins, and the
# host's map is drawn last.
boot = Studio::Engine.javascript_boot_graph
Studio::Engine.javascript_module_logical_paths.each do |logical_path|
  next if logical_path.start_with?("studio/vendor/")

  name = logical_path.delete_suffix(".js")
  pin name, to: logical_path, preload: boot.include?(name)
end
pin "@hotwired/stimulus", to: "studio/vendor/stimulus.js", preload: true
pin "sortablejs", to: "studio/sortable.js", preload: false
