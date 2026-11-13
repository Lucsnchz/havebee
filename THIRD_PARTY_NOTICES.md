# Third-party notices

The project license does not replace the licenses of third-party components.
Full upstream license texts and applicable notices are included in `LICENSES/`
and copied into `Havebee.app/Contents/Resources/` by `scripts/build-app.sh`.

## Swift packages

Versions and revisions below correspond to `Package.resolved`. Some transitive
packages are used only by particular upstream targets or platforms; their
notices are included for completeness.

| Component | Version / revision | License and notices |
| --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.99.0 / `2dad6a1e516f755bed77cf9bbd09455062f54758` | [MIT](LICENSES/SwiftTerm-MIT.txt) |
| [swift-png](https://github.com/tayloraswift/swift-png) | 4.5.1 / `8a0bcd4df5e4b307c804937776a56dd6ecdf6396` | [Apache-2.0](LICENSES/swift-png-Apache-2.0.txt), [NOTICE](LICENSES/swift-png-NOTICE.txt) |
| [h](https://github.com/rarestype/h) | 1.0.1 / `aa3626829160917d4378330617971977cbd78f5b` | [Apache-2.0](LICENSES/h-Apache-2.0.txt), [NOTICE](LICENSES/h-NOTICE.txt) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 / `6a52f3251125d74daf04fcbd5e6f08a75d074382` | [Apache-2.0](LICENSES/swift-argument-parser-Apache-2.0.txt) |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.1 / `ab7d71291238df6e0492143b120c9b696a35f603` | [MIT and bundled notices](LICENSES/Sparkle-MIT.txt) |

SwiftTerm's notice credits Miguel de Icaza, the xterm.js authors, SourceLair
Private Company and Christopher Jeffrey. The full notices are preserved in its
license file. The swift-png and h packages credit diana ma (@tayloraswift).
Sparkle is embedded as `Sparkle.framework` (automatic updates). Its license file
also carries the notices of the code it bundles (bsdiff, sais, ed25519 and
others), all preserved verbatim.

## Embedded agent logos

The SVG assets are embedded in `Sources/HiveKit/Views/LogoAssets.swift`.

### LobeHub Icons

- Source: [LobeHub Icons](https://github.com/lobehub/lobe-icons/tree/49a2130df7bfa5eb1b088261bff20a37e2967789),
  `@lobehub/icons-static-svg` version **1.95.1**.
- Copyright (c) 2023 LobeHub.
- License: [MIT](LICENSES/LobeHub-MIT.txt).
- Claude: `icons/claude-color.svg`, embedded without changes. Although originally
  obtained from a Claude Code extension, the embedded SVG is byte-for-byte
  identical to this MIT-licensed package asset.
- Grok: `icons/grok.svg`, embedded without changes and rendered as a template
  using the interface's text color.
- Codex: derived from `icons/codex-color.svg`. The white background was removed
  and SVG arc commands were rewritten for CoreSVG rendering.

### Dashboard Icons

- Source: [Dashboard Icons, google-gemini.svg](https://github.com/homarr-labs/dashboard-icons/blob/6d31345986eba2067a63eb41c1a5a87d4e8e850a/svg/google-gemini.svg).
- Maintained by Homarr Labs and contributors.
- License: [Apache-2.0](LICENSES/DashboardIcons-Apache-2.0.txt).
- The embedded Gemini SVG is byte-for-byte identical to the asset at the
  revision linked above. No upstream `NOTICE` file was present at that revision.

These copyright licenses do not grant rights to the underlying brands. The
logos identify third-party integrations; they do not imply endorsement.

## Other materials and tools

The [Developer Certificate of Origin 1.1](DCO) is reproduced unchanged from
<https://developercertificate.org/> with its own copyright and copying notice.

AI agent CLIs, Laravel Herd and other external applications are installed
separately and are not redistributed in this repository or app bundle.
System-provided symbols and frameworks are used through macOS APIs.

GitHub Actions and Gitleaks are development tools downloaded separately by CI;
their repositories and pinned versions are referenced in the workflow. They
are not bundled with the application.

When updating a dependency or copying an asset, update these notices and its
corresponding license files as part of the same change.
