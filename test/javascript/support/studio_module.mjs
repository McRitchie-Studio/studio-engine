// Loads an engine module (app/javascript/studio/<name>.js) from source for a
// node:test file, with each static `from "studio/<other>"` import replaced by
// that module's own source as a data: URL, recursively. A module that imports
// nothing can still be loaded the old way; this is for the ones that import a
// sibling (studio/voice_recorder imports studio/microphone and
// studio/level_meter). Not a test file itself: the runner globs *.test.mjs.
import { readFileSync } from "node:fs"

const ROOT = new URL("../../../app/javascript/", import.meta.url)

export function studioSource(name) {
  return readFileSync(new URL(`${name}.js`, ROOT), "utf8")
}

export function studioModuleUrl(name, seen = []) {
  if (seen.includes(name)) throw new Error(`import cycle: ${[...seen, name].join(" -> ")}`)
  const inlined = studioSource(name).replace(/(\bfrom\s+)"(studio\/[a-z_/]+)"/g, (_, from, dep) =>
    `${from}"${studioModuleUrl(dep, [...seen, name])}"`)
  return `data:text/javascript,${encodeURIComponent(inlined)}`
}

// A fresh instance each call (the fragment defeats the module cache), so a
// test that changes module state (configureMicrophone) does not leak.
export function loadStudioModule(name) {
  return import(`${studioModuleUrl(name)}#${Math.random()}`)
}
