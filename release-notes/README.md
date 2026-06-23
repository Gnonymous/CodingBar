# Release notes

One file per release, named `v<MAJOR>.<MINOR>.<PATCH>.md`. Used as the body of
the corresponding GitHub Release page.

## Workflow

`.github/workflows/release.yml` triggers on `v*` tag push, builds the `.app`,
packages a `.dmg` + `.zip`, and runs `gh release create … --generate-notes` —
which produces a minimal auto-changelog body.

To replace that minimal body with the file in this folder, after CI finishes:

```bash
gh release edit v1.1.0 --notes-file release-notes/v1.1.0.md
```

## File structure

Each notes file should cover:

1. **Highlights** — what's new, grouped by user-facing area, in plain prose.
2. **Performance / privacy / behavior changes** — when material.
3. **Install** — one-paragraph download + Gatekeeper workaround reminder.
4. **Full Changelog link** — `https://github.com/Gnonymous/CodingBar/compare/<prev>...<this>`.

Keep it readable to a non-contributor on the GitHub Releases page. Numbers and
concrete examples beat marketing copy.

## Older releases

`v1.0.0` and `v1.0.1` predate this folder; their bodies live only on the
GitHub Releases page.
