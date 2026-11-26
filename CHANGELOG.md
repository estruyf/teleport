# Changelog

All notable changes to Teleport. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). Each release's section here is also its GitHub release text and the notes in the app's update prompt.

## [Unreleased]

## [0.1.0] - 2026-11-26

The first release: use the apps on another Mac as if they were right here.

### Added

- **Portals.** Open a single window of an app on another Mac as a native window on yours, with its own Dock icon. Keyboard, mouse, scroll and resize go straight through.
- **One app, two modes.** A Mac is either the host (shares its apps) or the viewer (uses them); the first launch asks which.
- **Pairing with a code.** The host shows a one-time 6-digit code and both Macs show the same fingerprint before you allow it. No accounts and no cloud relay.
- **Discovery by name.** Hosts on the same network (Bonjour) or Tailscale tailnet show up by name.
- **Shared apps only.** Viewers see and open windows of the apps the host shares, nothing else.
- **Remote control of apps.** Launch apps, open new windows, and quit or force quit apps on the host, from the viewer's window or its menu bar item.
- **Clipboard and files.** Copied text syncs both ways; drop a file on a portal to send it to the host (experimental).
- **Headless hosts.** A virtual Retina display lets a Mac without a monitor render sharp windows.
- **Keeps running.** The viewer reconnects after a network drop and reopens its portals, the host restarts its streaming server if it dies, and a login item brings the host back after a reboot. Optional: keep the host from locking itself while hosting, and stay unlocked after a Screen Sharing sign-in.
- **Locked-host warning.** Viewers are told when the host is locked and typing won't work.
- **Host overview.** The host window shows status, pairing, who is connected and a readiness checklist on one screen, with Apps, Paired Macs and Keep it running in a sidebar.
- **Viewer sidebar.** Your paired Macs and Macs found nearby in a sidebar; windows already open in a portal are checked.
- **Automatic updates.** Signed updates through Sparkle. A viewer asks before installing; a host installs an update on its own while no Mac is connected, then goes back to hosting.
- **Homebrew.** `brew install --cask estruyf/tap/teleport`.

### Known limitations

- Apple Silicon only.
- The signalling connection isn't encrypted on a plain LAN yet; over Tailscale the whole path is. See [security](https://github.com/estruyf/teleport/blob/main/docs/security.md).
- No audio from remote apps yet.

[Unreleased]: https://github.com/estruyf/teleport/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/estruyf/teleport/releases/tag/v0.1.0
