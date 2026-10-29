# Teleport

Share individual app windows from a headless Mac (the **host**) to the Mac you sit at (the **viewer**), over the LAN or Tailscale. Each remote window is a native window on the viewer with a teal border, its own Dock icon with a remote badge, and full keyboard/mouse control. Think Parallels Coherence, but the apps run on another Mac.

## How it works

| Piece | Implementation |
|---|---|
| Transport | [LiveKit](https://livekit.io) (open-source WebRTC SFU) running on the host; the Swift SDK on both sides |
| Video | ScreenCaptureKit captures the owning app cropped to the window (so menus and popups show), H.264 at native Retina resolution |
| Control | LiveKit RPC (`list / apps / open / close / resize / launch / icon`) and a data channel for input |
| Input | Viewer sends normalised events; host raises the window via Accessibility and posts `CGEvent`s |
| Headless | Host creates a virtual Retina display ("Teleport Stage") with the private `CGVirtualDisplay` API |
| Dock | One `TeleportDockTile` stub per remote app, named after the app, with a badged icon |

Both Macs need macOS 14 or later.

## Setup

### Host (the headless Mac)

```sh
brew install livekit                 # provides livekit-server
swift build -c release
.build/release/TeleportHost          # creates ~/.teleport/config.json on first run
```

Grant **Screen Recording** and **Accessibility** to `TeleportHost` when macOS asks (System Settings → Privacy & Security). Over SSH you can pre-approve by running it once from a GUI session, or run it from a `launchd` agent in the Aqua session.

Edit `~/.teleport/config.json` to choose the apps you want to share (`allowedApps`, bundle IDs) and the virtual display size.

### Viewer (the Mac you work on)

```sh
scp host:~/.teleport/config.json ~/.teleport/config.json   # shared LiveKit key/secret
swift build -c release
.build/release/TeleportViewer
```

Enter the host's IP, hostname or Tailscale name and press Connect. Pick a window to open it, or **Launch** / **New window** on an app.

## Ports

`7880` (signalling, WebSocket), `7881` (RTC over TCP), `7882` (RTC over UDP). Over Tailscale no port forwarding is needed.

## Files

- `~/.teleport/config.json` — shared settings and credentials (mode 600)
- `~/.teleport/host.log`, `viewer.log`, `livekit-server.log`
- `~/.teleport/dock-tiles/` — generated Dock tile stubs and icons

## Status

Early spike. Working: discovery by address, window/app listing, launch, streaming, resize, mouse, keyboard, scroll, Dock tiles, remote border. Not yet: pairing/trust UI, Bonjour discovery, clipboard, audio, file drag, HEVC 4:4:4.
