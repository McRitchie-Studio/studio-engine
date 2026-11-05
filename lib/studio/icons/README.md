# Vendored icons

`lucide/` holds the line icons `studio_icon` renders, copied unchanged from the
`lucide-static` npm package, version 1.68.0. Lucide is under the ISC license, and its
Feather-derived icons (`log-out` here) are under MIT. Both texts are in
[`lucide/LICENSE`](lucide/LICENSE), which ships with the gem.

The files are vendored, and render inline, because a strict CSP allows no icon CDN.

To add an icon, copy its `.svg` from the same package version, and read it first. Vendor
only what a view uses. `test/lib/studio_icons_test.rb` holds each file to the shape the
helper reads.
