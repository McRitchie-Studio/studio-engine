# Branded loader

Every app draws its loader from its own icon, in its own theme colours, with no
per-app markup. One class, `.studio-loader`, sized by `--studio-loader-size`;
the style rides `data-loader-style`. Code: `lib/studio/loader.rb` (config and
art), `app/helpers/studio/loader_helper.rb`, `app/views/studio/loader/`,
`engine-motion.css` ("BRANDED LOADER") and `app/javascript/studio/loader.js`.
The six styles are the ones Alex McRitchie picked from the Loader Lab
(task `branded-app-loader`, 2026-10-28).

## Declare the style

In `config/initializers/studio.rb`; the default is `:breathe`, so an app that
says nothing still gets a branded loader:

```ruby
config.loader = :orbit
config.loader = { style: :sparkle, icon: "/brand/icon-dark.svg", art: "/brand/loader-sparkle.svg" }
```

| Key | Default | Meaning |
|---|---|---|
| `style` | `:breathe` | one of the styles below |
| `icon` | the navbar brand's logo, else theme_logos' "Navbar Logo" | the image every style draws |
| `art` | none | the marked-layer SVG a signature style needs |

An unknown style or key, or a signature style without `art`, raises at boot.

## The styles

| Style | Lab | Kind | Picked for |
|---|---|---|---|
| `breathe` | 01 | generic, the default | any app; buttons |
| `liquid` | 03 | generic, takes `percent:` | uploads, imports |
| `orbit` | 04 | generic | Commercial Welding (second style) |
| `steel` | 09 | generic | McRitchie Industries |
| `weld_bead` | 05 | signature, needs `art` | Commercial Welding |
| `sparkle` | 08 | signature, needs `art` | McRitchie Studio |

**Generic** styles draw the icon as an image and nothing else, so they fit any
app. **Signature** styles animate parts of the icon, which an image cannot
expose, so the app supplies an art file: an SVG in the **icon's own viewBox**
holding only the animated layers, marked with `data-loader`:

```xml
<!-- weld_bead: the one line the bead runs -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 264.3 300.2">
  <path data-loader="outline" d="M133.1 300C..."/>
</svg>

<!-- sparkle: each spark, in the order they flare; group transforms are kept -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 662.45 538.14">
  <g transform="translate(-2,-1.81)"><path data-loader="spark" d="..."/> ...</g>
</svg>
```

The icon is drawn underneath and the layers are inlined over it, so the two
files must share a viewBox. Art that is missing, outside `public/`, or has no
marked layer falls back to Breathe rather than blanking the loader.

## Use it

```erb
<%= studio_loader %>                               <%# 96px, the app's style %>
<%= studio_loader size: 20, label: "Saving" %>     <%# inline, beside text %>
<%= studio_loader style: :liquid, percent: 40 %>   <%# a fill that follows a percent %>
<%= studio_loader_overlay %>                       <%# the page-load overlay: once, in the layout body %>
```

- **Page loads.** `studio_loader_overlay` renders hidden. `studio/loader`
  shows it when a Turbo visit outlasts its `delay:` (350ms) and hides it when
  the page arrives, so a fast load never flashes it. A form marked
  `data-studio-loader-overlay="Caption"` shows it while it submits.
  `window.StudioLoader.show("Caption")` / `.hide()` cover any other long wait.
- **Pending buttons.** Put `studio_loader_pending` inside the button (a small
  Breathe in the button's text colour) and mark what it replaces
  `data-loader-idle`. It shows while the button or its form is
  `aria-busy="true"`: Turbo marks a submitting form itself; for a form Turbo
  does not drive, `studio/loader` marks the submitter.
- **Percent.** `StudioLoader.setPercent(el, n)` moves a `percent:` loader.

## Colours

`--studio-loader-color` (halo, frame, sparkle tint) is `--color-primary` and
`--studio-loader-hot` (the orbiting spark) is `--color-accent`, both from the
app's theme tag. The bead's cooling colours are `--studio-loader-bead-1..6`.

## Reduced motion

Under `prefers-reduced-motion: reduce` every loader is a still icon: no
animation, and the halo, orbit spark, bead and sparkle flares are not drawn.

## Lab

`/lab/loader` in the dummy app (`e2e/loader.spec.js`) shows every style on its
brand from `test/fixtures/files/loader`.
