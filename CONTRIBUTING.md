# Contributing to NovaCAD

Thanks for your interest in improving NovaCAD. Contributions of all sizes are
welcome — bug reports, fixes, tests, docs, and focused features.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6 toolchain)
- No third-party dependencies: everything builds with the Swift toolchain alone

## Building, running, testing

```sh
swift build                              # compile (debug)
swift run -c release NovaCAD             # run; release is recommended for large drawings
swift test                               # run the XCTest suite (1,200+ cases)
```

## Installing as a Mac app

```sh
./Scripts/build_app.sh                   # build NovaCAD.app and install it to /Applications
./Scripts/build_pkg.sh                   # produce a distributable .pkg
```

The install script ad-hoc signs the app; the packaging script creates an
unsigned installer. Neither is Developer ID signed or notarized, so macOS
may require approval in System Settings → Privacy & Security.

Before installing, add a plain-language highlight in `WhatsNew.recentHighlights`
in `Sources/DWGViewer/App/WelcomeView.swift`. The marketing version comes from
`AppVersion.fallback`; bump it when a change warrants showing What's New again.

## How to contribute

1. Fork the repository and create a branch from `main`.
2. Make your changes.
3. Run the full test suite (`swift test`) and make sure it passes.
4. Open a pull request.

The `michaeljabbour/NovaCAD-Mac` fork and `ryandirezze/NovaCAD-Mac` upstream
have separate histories and releases. Confirm the intended target repository
and base branch before opening a PR. A review branch should contain only the
changes intended for that base; do not rewrite already-published `main` history.

Keep pull requests focused — one logical change per PR is easier to review.
In the description, explain what changed and why. For bug fixes, include
reproduction steps (ideally a minimal synthetic DXF) so reviewers can verify
the fix.

## Before requesting review

```sh
swift build
swift test
git diff --check
git diff --stat <base>...HEAD
```

Use the actual PR base in place of `<base>`. Give the reviewer the branch,
commit, base, problem, changed behavior, test results (including skips), and
any behavior that was not checked live. Keep the README, feature inventory,
and changelog consistent with the code. UI changes need a live check in the
installed build; unit tests alone do not verify hit targets or panel placement.

For workspace changes, check fitted and manually panned views with panels
open and closed, Model/Paper and sheet switching, search open/close, keyboard
shortcuts, and accessibility selection/help. Use a synthetic fixture for
committed evidence. If a private drawing is used locally, keep it and its
screenshots out of the commit and confirm it was not changed.

## Testing expectations

- All tests must pass before a PR is merged.
- New parser or geometry behavior needs a regression test that would fail
  without your change.
- Test fixtures must be SMALL SYNTHETIC DXF files that you wrote yourself.
  Never commit real, proprietary, or customer drawings, and never include
  company-confidential content — this applies equally to files, issue text,
  pasted snippets, and screenshots in issues or PRs.

## Code style

- Follow the style of the file you are editing; match its naming, formatting,
  and structure.
- Do not add third-party dependencies.
- Performance-sensitive paths (the parser and `Regenerator`) should stay
  allocation-conscious — avoid unnecessary copies and intermediate arrays.
- Comment only where the "why" is non-obvious; let the code explain the "what".

## Licensing

Contributions are accepted under the Apache License 2.0 (see `LICENSE`). By
submitting a pull request you confirm that you wrote the code (or otherwise
have the right to contribute it) and that it may be distributed under that
license.

## Security and privacy

If a report involves a potential data leak or security vulnerability, do not
paste sensitive drawing data into an issue. Describe the problem minimally —
what happens, and how to reproduce it with a synthetic file — and leave out
anything confidential.
