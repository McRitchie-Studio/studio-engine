- **A shared chat head morphs on a slow device too.** On a first visit to a page,
  `studio/page_transitions` reads the new page's `data-vt-morph` names from the
  response and lets the shared name through before the browser takes the old
  page's picture. That read raced Turbo's own read of the same response: under
  load Turbo could start the view transition first, and the element faded
  instead of morphing (2 of 6 visits under an 8x CPU throttle). Turbo now reads
  the response through the module's read, so the names are always known first.
  `studio/reload_visits` hid the race where it loads first; the module no longer
  depends on that. Nothing for a consumer to change.
