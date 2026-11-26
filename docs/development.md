# Development

Teleport builds with SwiftPM and the Xcode Command Line Tools; Xcode is not needed. The npm scripts are thin wrappers, so `node` is only there to run them.

## Build and run

```sh
npm run deps      # brew install livekit
npm run bundle    # swift build + build/Teleport.app
npm run start     # bundle and open the app
npm run stop      # stop every Teleport process and livekit-server
```

`scripts/bundle.sh` wraps the build into `build/Teleport.app`: icon, Info.plist, the `TeleportDockTile` stub and `livekit-server` (from Homebrew, pinned version in the script). It signs with your Developer ID when one is in the keychain, and ad hoc otherwise. Keep the same signature between builds: macOS ties Screen Recording and Accessibility to it, so an ad-hoc build loses those grants on every rebuild.

> The Command Line Tools have no SwiftUI macro plugins, so `@State` doesn't compile. Views use the `@Local` property wrapper in `UI/Components.swift` instead.

## Scripts

| Script | What it does |
|---|---|
| `npm run build` / `build:release` | `swift build` |
| `npm run bundle` / `bundle:release` | Build and wrap into `build/Teleport.app` |
| `npm run start` / `start:release` | Bundle and open the app |
| `npm run start:loopback-host` | A second instance as host with `TELEPORT_HOME=~/.teleport-host`, for testing on one Mac |
| `npm run stop` | Stop every Teleport process and livekit-server |
| `npm run test` | Run the TeleportCore tests (Swift Testing) |
| `npm run dist` / `dist:notarized` | Release zip in `dist/`, notarized with `NOTARY_PROFILE` ([releasing](releasing.md)) |
| `npm run icon` | Regenerate `Resources/AppIcon.icns` from `scripts/make-icon.swift` |
| `npm run logs` / `logs:livekit` / `logs:stats` | Follow the logs; `stats.log` needs `video.stats` |
| `npm run test-pattern` | Build and open the test-pattern window for measuring video ([video quality](video-quality.md)) |
| `npm run clean` | Remove `.build` and `build` |

## Testing on one Mac

See [try it on one Mac](getting-started.md#try-it-on-one-mac): `npm run start:loopback-host` runs a host with its own identity next to a normal viewer instance, and you pair the viewer with `127.0.0.1`.

## Tests and CI

```sh
npm run test   # swift test with the Command Line Tools' testing plugin
swift test     # when Xcode is the active toolchain
```

The tests cover the pairing crypto, config compatibility, the video settings and the test pattern. GitHub Actions ([`ci.yml`](../.github/workflows/ci.yml)) runs `swift build` and `swift test` on macOS for every push to `main` and every pull request. [`release.yml`](../.github/workflows/release.yml) builds and publishes releases.

## Release builds

```sh
# one-time: store an app-specific password for notarization
xcrun notarytool store-credentials teleport --apple-id <your Apple ID> --team-id <your team ID>

npm run dist:notarized   # NOTARY_PROFILE=teleport scripts/release.sh
```

`scripts/release.sh` makes a release build, signs it with the hardened runtime (`scripts/entitlements.plist`), and zips it into `dist/Teleport-<version>-arm64-mac.zip`. With notary credentials it is notarized and stapled, so Gatekeeper accepts it on another Mac. Without them the zip is built but not notarized. Only release bundles carry the Sparkle feed, so only they update themselves.

Publishing a GitHub release does all of this in CI, plus the appcast and the Homebrew cask: see [releasing and updates](releasing.md). What's left before a first release is in the [release checklist](release-checklist.md).

## Video measurements

`TeleportTestPattern` draws stamped frames, and the viewer's probe reads them back to measure latency and frame rate end to end. The harness, the `video` settings and the A/B tests to run are in [video quality](video-quality.md).
