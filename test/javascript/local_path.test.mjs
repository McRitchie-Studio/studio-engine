// [unit] studio/local_path: isLocalPath, the browser twin of
// Studio::LocalPath.local?. Loaded from source as a data: module so it runs on
// node:test with no package.json "type" and no npm install.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/local_path.js", import.meta.url), "utf8")
const { isLocalPath } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("a path on this site passes", () => {
  for (const path of ["/", "/ok", "/contests/world-cup", "/a/b?c=d#e"]) {
    assert.equal(isLocalPath(path), true, JSON.stringify(path))
  }
})

test("every way off the site is refused", () => {
  const offSite = ["//x", "/\\x", "/\\/x", "\t/x", "/\tx", "/\n/x", "/\x7Fx",
                   "https://x", "javascript:x", "x", "", " "]
  for (const path of offSite) {
    assert.equal(isLocalPath(path), false, JSON.stringify(path))
  }
})

test("null and undefined are not local", () => {
  assert.equal(isLocalPath(null), false)
  assert.equal(isLocalPath(undefined), false)
})
