# Teleport

Use apps from another Mac as if they were here. Teleport streams individual app windows from a Mac in the office (the **host**, with or without a screen) to the Mac you work on (the **viewer**), over the LAN or Tailscale. Each remote window is a native window with a violet border and its own badged Dock icon, and takes your keyboard, mouse and dropped files. Think Parallels Coherence, but the apps run on another Mac.

One app, two modes. The first launch asks which one this Mac is.

## How it works

| Piece | Implementation |
|---|---|
| Transport | [LiveKit](https://livekit.io) (open-source WebRTC SFU) running on the host; the Swift SDK on both sides |
| Video | ScreenCaptureKit captures the owning app cropped to the window (so menus and popups show), H.264 at native Retina resolution |
| Control | LiveKit RPC (`apps / open / close / resize / launch / icon`), a data channel for input, byte streams for dropped files |
| Input | Viewer sends normalised events; host raises the window via Accessibility and posts `CGEvent`s |
| Pairing | X25519 device keys. The host shows a one-time 6-digit code (2 minutes, 5 tries); the code is never sent, it salts the key the request is sealed with, so the request only opens on the host whose code you typed. The host shows a fingerprint and asks Allow. Paired viewers get one-hour LiveKit tokens from the host's control endpoint (LiveKit refreshes them while connected). The LiveKit secret never leaves the host. |
| Headless | Host creates a virtual Retina display ("Teleport Stage") with the private `CGVirtualDisplay` API |
| Dock | One `TeleportDockTile` stub per remote app, named after the app, with a badged icon |
| Discovery | Bonjour `_teleport._tcp` on the LAN; Tailscale peers (via the Tailscale CLI) probed for a Teleport host |
| Clipboard | Text, both ways, over the data channel (up to 14 KB) |
| Resilience | The viewer reconnects for two minutes after a drop and reopens its windows; the host restarts `livekit-server` if it dies; a login item keeps the host up after a reboot |

Both Macs need macOS 14 or later. Built with SwiftPM; no Xcode needed.

## Setup

```sh
npm run deps        # brew install livekit (bundled into the app at build time)
npm run bundle      # swift build + build/Teleport.app, signed with your Developer ID when present
open build/Teleport.app
```

For another Mac: `npm run dist` builds a release zip in `dist/`; with `NOTARY_PROFILE` set (see `scripts/release.sh`) it is notarized and stapled so Gatekeeper accepts it.

**Host (the office Mac):** choose *This Mac shares its apps*. Grant **Screen Recording** and **Accessibility** when asked (the window shows a notice with a button to System Settings while either is missing). Nothing is shared until you add apps under *Shared apps* (search installed apps, or drop an .app on the sheet). The host lives in the menu bar; the window reopens from there.

**Viewer (the Mac you work on):** choose *This Mac shows remote apps*. Press *Pair a new Mac*; hosts on the same network or tailnet are listed, or type the address (shown on the host, Tailscale address first). Enter the 6-digit code from *Show pairing code* on the host. The host asks to allow; both sides show the same fingerprint. After that, *Connect* and open or launch apps.

### Loopback test on one Mac

```sh
npm run start:loopback-host   # a second instance as host, with its own identity in ~/.teleport-host
open -n build/Teleport.app    # the viewer; pair with 127.0.0.1
```

Granting Screen Recording makes macOS offer *Quit & Reopen*. That quits every instance of the bundle and relaunches one without `TELEPORT_HOME`, so start the loopback host again afterwards.

## Scripts

| Script | What it does |
|---|---|
| `npm run build` / `build:release` | `swift build` |
| `npm run bundle` / `bundle:release` | build and wrap into `build/Teleport.app` (icon, Info.plist, ad-hoc signature) |
| `npm run test` | run the TeleportCore tests (Swift Testing) |
| `npm run dist` / `dist:notarized` | release zip in `dist/`, notarized with `NOTARY_PROFILE` |
| `npm run icon` | regenerate `Resources/AppIcon.icns` from `scripts/make-icon.swift` |
| `npm run start` | bundle and open the app |
| `npm run start:loopback-host` | second instance as host, for testing on one Mac |
| `npm run stop` | stop every Teleport process and livekit-server |
| `npm run logs` / `logs:livekit` | follow the logs |
| `npm run clean` | remove `.build` and `build` |

## Ports

`7880` signalling (WebSocket), `7881` RTC over TCP, `7882` RTC over UDP, `7883` control (pairing and tokens). Over Tailscale no port forwarding is needed.

## Files

All under `~/.teleport` (or `$TELEPORT_HOME`):

- `config.json`: mode, name, port, shared apps, virtual display; on a host also its LiveKit key and secret (mode 600)
- `device.key`: this Mac's private key (mode 600); `trust.json`: viewers the host allowed; `hosts.json`: hosts the viewer paired with
- `app.log`, `livekit-server.log`, `livekit.pid`
- `dock-tiles/`: generated Dock tile stubs and icons

## Docs

- [docs/release-checklist.md](docs/release-checklist.md): what is left for a first release
- [docs/security.md](docs/security.md): the trust model, known gaps, and how Beam does linking

## Status

Working: pairing, tokens, discovery by name, app and window listing, launch and new window, streaming, resize, mouse, keyboard, scroll, clipboard text, Dock tiles, remote border, file drop (experimental), reconnect, login item, menu bar item, bundled livekit-server, release script, tests and CI. Not yet verified on a headless Mac. Not yet: TLS on the signalling socket (on a plain LAN the session token travels over `ws://`; Tailscale covers it), audio, HEVC 4:4:4, Sparkle updates.
