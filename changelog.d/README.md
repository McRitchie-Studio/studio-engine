# Changelog fragments

Do not edit `CHANGELOG.md` in a PR. Add one file here for each change:

```text
changelog.d/<slug>.<kind>.md
```

- `<slug>`: the task slug (lower-case letters, digits and hyphens).
- `<kind>`: `added`, `changed`, `deprecated`, `removed`, `fixed` or `security`.
- The body: the entry as Markdown list item(s), in the form `CHANGELOG.md` already
  uses (`- **What changed.** Why, and what a consumer does.`). Write no `## ` or
  `### ` heading. The file name gives the kind, and the release gives the version.

One change with two kinds is two files, for example `my-task.added.md` and
`my-task.fixed.md`.

## Why

Two PRs that both edit `## Unreleased` conflict on GitHub, because GitHub's merge
check ignores `.gitattributes` merge drivers. Two PRs that add two different files
cannot conflict.

## What happens at release

`bin/changelog-compile` folds every fragment into `## Unreleased`, under its
`### <Kind>` subsection (Added, Changed, Deprecated, Removed, Fixed, Security), in
file-name order, and deletes the fragments. `bin/release prepare` then rolls
`## Unreleased` into the allocated version heading. Both ride the `Release <version>`
commit. `bin/changelog-compile --dry-run` prints the compiled section and writes
nothing. See `docs/RELEASE.md`, *Changelog fragments*.

## The check

`bin/changelog-check` runs on every pull request in Engine CI. It fails when a
fragment here is malformed, when the PR adds lines under `## Unreleased`, or when the
PR changes what the gem ships (`lib/`, `app/`, `config/`, `db/`, the gemspec) and adds
no fragment. Run it locally with `bin/changelog-check --base origin/accepted`.
