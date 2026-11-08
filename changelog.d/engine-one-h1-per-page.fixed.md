- **One h1 per page: the navbar's brand gives way to the page's own h1.** The
  navbar drew the brand as an h1 unless the layout passed `brand_heading: false`,
  so a page with the standard header (`studio/_page_header`) carried two h1s, and
  an app that passed `false` everywhere left pages with none (the profile, the
  error logs). Now `studio/_page_header` records its h1, the navbar also reads
  the page body for an `<h1>` tag (`studio_page_has_h1?`), and the brand is a div
  with the same classes only when the page has its own. An explicit
  `brand_heading:` still wins, and a `preview: true` navbar keeps the h1. A
  consumer test that selects the brand as `h1.nav-title` on a page with its own
  h1 must select `.nav-title`; an app that passes `brand_heading: false` on every
  page, or computes it from the page body, can drop the local.
