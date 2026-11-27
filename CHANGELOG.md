# Changelog

All notable changes to Teleport. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). Each release's section here is also its GitHub release text and the notes in the app's update prompt.

## [Unreleased]

## [0.3.0] - 2026-11-27

Screenshots, downloads and unread counts come along, and the menu bar tells you how the host is doing.

### Added

- **Images on the clipboard.** Copy a screenshot on one Mac and paste it into a chat on the other, both ways, up to 25 MB.
- **Downloads come to you.** A file a shared app saves to the host's Downloads, such as a Teams attachment, lands in your Downloads with a notification. Other apps' downloads stay on the host.
- **Unread counts.** A shared app's Dock badge shows on its Dock icon on your Mac and in the menu bar's app list, even before you open one of its windows.
- **Host health in the menu bar.** The icon turns orange while the host is locked and red while the connection is lost. While you're not connected, the menu shows each paired Mac as online or offline, and can wake one that sleeps on the same network.

### Known limitations

- The host asks once for access to its Downloads folder, and doesn't send downloads until someone answers. On a Mac without a screen, answer it through Screen Sharing; the host's checklist says when it's waiting.
- Wake only reaches a host on the same local network, with *Wake for network access* on. Over Tailscale it can't wake a sleeping Mac.
- These were tested with both Macs' roles on one Mac, not yet across two.

## [0.2.0] - 2026-11-27

Hear the shared apps, talk in their calls, and get their notifications.

### Added

- **Sound.** Hear the shared apps on the viewer: Teams ringing, a video, the other side of a call. The host plays nothing itself and needs no microphone or speakers. On by default; turn it off in the host window's new Sound section or the viewer's Settings › Sound.
- **Microphone for calls (optional).** Turn it on on the viewer, and set up a virtual audio device such as BlackHole on the host: its new Sound section checks the setup and can run the install in Terminal. The viewer then sends its microphone, with echo cancellation, only while a shared app on the host is listening to one.
- **Notifications from shared apps.** Banners that the host's shared apps show appear on the viewer, with the app's icon. Click one to open that app where the notification points. Other apps' notifications stay on the host. On by default; turn it off on either Mac under Settings › Between Macs.

### Known limitations

- Sound and notifications were tested with both Macs' roles on one Mac, not yet with Teams across two Macs. The host log (`npm run logs`) shows `sound:` and `notifications:` lines if something doesn't come through.
- Sound is mono.
- No banner is forwarded while the app that sends it is frontmost on the host; macOS hands it to the app instead.

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

[Unreleased]: https://github.com/estruyf/teleport/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/estruyf/teleport/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/estruyf/teleport/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/estruyf/teleport/releases/tag/v0.1.0
