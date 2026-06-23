# Release notes

One file per release, `v<MAJOR>.<MINOR>.<PATCH>.md`. Used as the GitHub
Release body.

## Workflow

`.github/workflows/release.yml` runs on `v*` tag push and creates the
Release with `--generate-notes` (minimal auto-body). After CI finishes,
overwrite the body:

```bash
gh release edit vX.Y.Z --notes-file release-notes/vX.Y.Z.md
```

## Style — concise, like a good commit

A few bullets of what changed and why. No marketing prose, no
section-by-section template, no headings unless there's a real reason.
If the release only fixes bugs, one paragraph is enough.

Ship the install hint only when something about install changes (new
arch, new minimum macOS, new Gatekeeper quirk). Otherwise skip it —
users who got here already know how to install.

Always end with the Full Changelog link:

```
**Full Changelog**: https://github.com/Gnonymous/CodingBar/compare/<prev>...<this>
```

## Older releases

`v1.0.0` and `v1.0.1` predate this folder; their bodies live only on
the GitHub Releases page.
