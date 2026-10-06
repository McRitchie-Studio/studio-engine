// The one rule for "is this a path on THIS site?", in the browser. It is the
// twin of Studio::LocalPath.local? (lib/studio/local_path.rb), and
// test/lib/studio/local_path_js_parity_test.rb holds the two to the same rows.
//
// A local path begins with exactly one "/" and carries no control character and
// no backslash. Each clause closes a way a browser leaves the site: no leading
// "/" is a scheme or a relative path, "//x" is another host, a backslash is read
// as "/", and the URL parser strips tab and newline, so a control character can
// hide a second "/".
//
// Pinned for every host as "studio/local_path" (config/importmap.rb).

// A control character (C0 or DEL) or a backslash anywhere in the path.
const UNSAFE_CHARACTER = /[\u0000-\u001f\u007f\\]/

export function isLocalPath(path) {
  const string = path == null ? "" : String(path)
  return string.startsWith("/") && !string.startsWith("//") && !UNSAFE_CHARACTER.test(string)
}
