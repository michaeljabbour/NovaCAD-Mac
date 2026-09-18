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

Both scripts are ad-hoc signed; recipients may need to allow the app in
System Settings → Privacy & Security on first launch.

## How to contribute

1. Fork the repository and create a branch from `main`.
2. Make your changes.
3. Run the full test suite (`swift test`) and make sure it passes.
4. Open a pull request.

Keep pull requests focused — one logical change per PR is easier to review.
In the description, explain what changed and why. For bug fixes, include
reproduction steps (ideally a minimal synthetic DXF) so reviewers can verify
the fix.

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
