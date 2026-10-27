// Installs importmap_hooks.mjs for `node --test`. A host's own register file
// (loaded with `node --import`) names its prefixes and calls this once:
//
//   import { registerImportmapHooks } from "../../../node_modules/.studio-engine/node_test/register.mjs";
//   registerImportmapHooks({
//     root: new URL("../../../", import.meta.url),
//     prefixes: { board: "app/javascript/board/" },
//     topLevelDir: "app/javascript/",
//     esmDirs: ["app/javascript/", "test/javascript/"],
//   });
//
// Paths are relative to `root`, the host's Rails root.
import { register } from "node:module";

export function registerImportmapHooks({ root, prefixes = {}, topLevelDir = null, esmDirs = [] }) {
  if (!root) throw new Error("registerImportmapHooks: root is required");
  register("./importmap_hooks.mjs", import.meta.url, {
    data: { root: String(root), prefixes, topLevelDir, esmDirs },
  });
}
