- **A PR adds a `changelog.d/<slug>.<kind>.md` fragment. It no longer edits
  `CHANGELOG.md`.** 39 of the last 40 engine PRs edited `## Unreleased`, and 15 of 40
  needed a merge-forward, because GitHub's merge check ignores the file's `merge=union`
  driver. Two PRs now add two different files, so they cannot conflict.
  `bin/changelog-compile` folds the fragments into `## Unreleased` by kind and deletes
  them; the release runs it before it rolls the version heading (`--dry-run` prints the
  result). `bin/changelog-check` runs in Engine CI on every pull request: it reddens a
  malformed fragment, a new line under `## Unreleased`, and a change to `lib/`, `app/`,
  `config/`, `db/` or the gemspec with no fragment (changelog.d/README.md,
  docs/RELEASE.md, "Changelog fragments"; task `changelog-fragments`).
