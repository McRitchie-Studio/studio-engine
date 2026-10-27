// Resolve importmap specifiers under `node --test` the way the browser does.
//
// In the browser, config/importmap.rb pins a directory under a prefix (`board`,
// `cyvasse`, `studio`), and the modules import each other as "board/colors".
// Node has no import map, so this hook maps each prefix onto the same files. A
// bare top-level name with a file of its own in `topLevelDir`
// (`import … from "chat_follow"`, pinned by name) maps the same way.
//
// A Rails app has no package.json "type", so Node would read a .js file as
// CommonJS. Files under `esmDirs` are ES modules (that is what the browser
// loads), so this hook says so.
//
// Configured by register.mjs through `initialize(data)`; it holds no app's names.
import { existsSync } from "node:fs";

let prefixes = [];
let topLevel = null;
let esmDirs = [];

const asDir = (url) => (url.endsWith("/") ? url : `${url}/`);

export function initialize({ root, prefixes: map = {}, topLevelDir = null, esmDirs: dirs = [] } = {}) {
  const base = asDir(String(root));
  prefixes = Object.entries(map).map(([prefix, dir]) => [prefix, asDir(new URL(dir, base).href)]);
  topLevel = topLevelDir ? asDir(new URL(topLevelDir, base).href) : null;
  esmDirs = dirs.map((dir) => asDir(new URL(dir, base).href));
}

function mapped(specifier) {
  for (const [prefix, dir] of prefixes) {
    const match = specifier.startsWith(`${prefix}/`) && /^[\w/-]+$/.test(specifier.slice(prefix.length + 1));
    if (match) return new URL(`${specifier.slice(prefix.length + 1)}.js`, dir).href;
  }
  if (topLevel && /^[a-z_]+$/.test(specifier)) {
    const file = new URL(`${specifier}.js`, topLevel);
    if (existsSync(file)) return file.href;
  }
  return null;
}

export async function resolve(specifier, context, nextResolve) {
  const target = mapped(specifier);
  const resolved = await nextResolve(target || specifier, context);
  if (resolved.url.endsWith(".js") && esmDirs.some((dir) => resolved.url.startsWith(dir))) {
    return { ...resolved, format: "module" };
  }
  return resolved;
}
