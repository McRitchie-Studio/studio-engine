# studio-engine Node tooling

The one Node tooling package every host shares. It ships inside the gem, so a
host gets it with the engine it already bundles: no npm registry, no token.

- `versions.json`: the pin set. Node's major, and the exact version of every
  shared npm package. A host that declares one of these packages declares it at
  exactly this version.
- `playwright_base.js`: the browser lane's shared defaults (one chromium
  project, one worker, a Rails `webServer` on `/up`).
- `e2e_helpers.js`: `watchPageErrors` and `blockOffsiteRequests`.
- `node_test/register.mjs` and `node_test/importmap_hooks.mjs`: let `node --test`
  import a module by the bare name the importmap pins it under.

Every file here requires only `node:` builtins and its own siblings, because it
is loaded from the gem's directory, which has no `node_modules`.

A host links the package into its own tree and checks itself against the pins:

```sh
bin/rails studio:node:link    # node_modules/.studio-engine -> this directory
bin/rails studio:node:check   # exits 1, naming each pin the host drifts from
```

Run `link` after `npm ci`, because `npm ci` deletes `node_modules`. Then
`require("./node_modules/.studio-engine/playwright_base.js")`. The adoption
steps are in the engine repository's `docs/FRONT_END_STANDARD.md`, "Node tooling".
