# Configuration

Most settings are in the app. This page covers what lives on disk, the network ports, and the settings that are only in `config.json`.

## Files

Everything is in `~/.teleport`, or in `$TELEPORT_HOME` when that is set.

| File | What it holds |
|---|---|
| `config.json` | Mode, name, port, shared apps, virtual display and the other settings below. On a host also its LiveKit key and secret. Mode 600. |
| `device.key` | This Mac's private X25519 key. Mode 600. Never leaves the Mac. |
| `trust.json` | Host: the viewers it allowed (name, public key, paired at). |
| `hosts.json` | Viewer: the hosts it paired with (name, address, port, public key). |
| `app.log` | The app's log, rotated at 10 MB. `npm run logs` follows it. |
| `livekit-server.log`, `livekit.yaml`, `livekit.pid` | Host: the streaming server's log, config and process id. |
| `~/Library/Preferences/ai.teleport.app.plist` | Window position and the updater's state (Sparkle's `SU…` keys). |
| `stats.log` | One line a second per portal when `video.stats` is on; see [video quality](video-quality.md#statslog). |
| `dock-tiles/` | Viewer: generated Dock tile stubs and their icons. |

## config.json

**Quit Teleport before editing.** The running app writes `config.json` back from memory, so edits made while it runs are lost.

| Key | Default | What it does |
|---|---|---|
| `mode` | unset | `"host"` or `"viewer"`. Unset shows the first-launch screen. |
| `deviceName` | the Mac's name | Shown to the other Mac when pairing and in discovery. |
| `port` | `7880` | LiveKit signalling port; the others follow from it (see [ports](#ports)). |
| `allowedApps` | `[]` | Bundle IDs the host shares. Edited from *Apps to teleport*. |
| `virtualDisplay` | on, 1920×1200, HiDPI | `enabled`, `width`, `height` (points) and `hiDPI` for the host's virtual display. |
| `livekitServerPath` | unset | An explicit path to `livekit-server`, instead of the bundled one or Homebrew's. |
| `clipboardSync` | on | Share clipboard text with the other Mac. |
| `sounds` | off | A short sound when a portal opens or a Mac pairs. |
| `downloads` | on | Host: send files the shared apps save to Downloads. Viewer: save them to Downloads here. |
| `audio` | on | Host: send the shared apps' sound (the *Sound* section). Viewer: play it (*Settings › Sound*). See [sound and microphone](getting-started.md#sound-and-microphone). |
| `microphone` | off | Viewer: send this Mac's microphone while a shared app on the host listens to one. |
| `microphoneDevice` | unset | Host: UID of the virtual audio device the viewer's microphone plays into. Unset picks a BlackHole device; `""` turns it off. |
| `notifications` | on | Host: send banners from shared apps to the viewer. Viewer: show them. See [notifications](getting-started.md#notifications). |
| `keepAlive` | off | Host: count as in use while hosting, so an idle-lock policy doesn't lock it. Same as the toggle in the app. |
| `video` | unset | Video tuning for A/B tests. Every key is documented in [video quality](video-quality.md#settings). |
| `apiKey`, `apiSecret`, `room` | generated | The host's own LiveKit credentials. Viewers never see the secret. |

Example of a host sharing two apps on a 2560×1440 virtual display:

```json
{
  "mode": "host",
  "deviceName": "Office Mac mini",
  "port": 7880,
  "allowedApps": ["com.microsoft.VSCode", "com.apple.Terminal"],
  "virtualDisplay": { "enabled": true, "width": 2560, "height": 1440, "hiDPI": true },
  "keepAlive": true
}
```

## Ports

All on the host, counted from `port`:

| Port | Protocol | Use |
|---|---|---|
| `7880` | TCP | LiveKit signalling (WebSocket) |
| `7881` | TCP | WebRTC media over TCP |
| `7882` | UDP | WebRTC media over UDP |
| `7883` | TCP | Control endpoint: pairing and session tokens |

On a LAN these need to be reachable from the viewer. Over Tailscale no port forwarding is needed. The signalling socket is plain `ws://` for now; [security](security.md#known-gaps-do-before-trusting-an-untrusted-lan) explains what that means on an untrusted network.

## Environment variables

| Variable | What it does |
|---|---|
| `TELEPORT_HOME` | Use another folder than `~/.teleport`, with its own identity and settings. Used for a [loopback test](getting-started.md#try-it-on-one-mac). |
| `TELEPORT_FEED_URL` | Point the updater at another appcast and check it right away, to try an update before releasing it. See [releasing](releasing.md#trying-an-update-before-it-ships). |
| `NOTARY_PROFILE` | For `scripts/release.sh`: the `notarytool` keychain profile to notarize with. See [releasing](releasing.md#releasing-from-a-mac). |
