# Contributing to Docky

Thanks for your interest in improving Docky. Contributions of all kinds are
welcome: bug reports, fixes, features, and documentation.

## Community

Join the [Docky Discord](https://discord.gg/vAwVNtPSgE) to ask questions, share
widgets, and follow development. [Sponsors](https://github.com/sponsors/josejuanqm)
get a supporter role there.

## Reporting issues

Open an issue at https://github.com/josejuanqm/docky/issues. Helpful reports
include:

- macOS version and Mac model
- Docky version (Settings shows the build)
- Steps to reproduce
- A diagnostic bundle: Settings -> Feedback builds one and reveals it in Finder,
  so you can attach it to the issue.

## Development setup

1. Fork and clone the repository.
2. Open `Docky.xcodeproj` in Xcode 16 or later.
3. Build and run the `Docky` scheme.

The project uses Xcode's file-system-synchronized groups, so new source files
under `Docky/` are picked up automatically without editing the project file.

### Signing

Sign with your own certificate before you start:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# then set DEVELOPMENT_TEAM to your team ID
```

That file is gitignored. A free Apple ID added under Xcode -> Settings ->
Accounts is enough — it creates a Personal Team and issues the certificate.

Without it, builds fall back to ad-hoc signing so a fresh clone still compiles.
That fallback works, but Docky needs Accessibility and Screen Recording, and an
ad-hoc identity changes whenever the binary does, so macOS keeps treating each
build as a new app and dropping those grants. `Config/Signing.xcconfig` has the
details.

Configure signing by editing that file, not through Xcode's Signing &
Capabilities tab — the tab writes literal values into `Docky.xcodeproj` and
would put a hardcoded team back in the repo.

## Pull requests

- Branch off `main` and keep changes focused.
- Match the surrounding code style; Docky leans on AppKit + SwiftUI and uses
  explanatory comments only where the reasoning is non-obvious (for example, the
  private-API usage in `Docky/Private/`).
- Verify the app builds and runs before opening a PR:

  ```sh
  xcodebuild -project Docky.xcodeproj -scheme Docky \
    -configuration Debug -destination 'platform=macOS' build
  ```

- Describe what changed and why, and include before/after notes or screenshots
  for UI changes.

## Private APIs

Docky relies on private SkyLight / CoreGraphics Services and Accessibility SPI.
When touching `Docky/Private/`, document why a given call is needed and what
breaks without it, so the next reader understands the tradeoff.

## License

By contributing, you agree that your contributions are licensed under the
GNU General Public License v3.0, the same license that covers the project.
