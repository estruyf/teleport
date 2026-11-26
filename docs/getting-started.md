# Getting started

Teleport is one app with two modes. The **host** is the Mac whose apps you want to use (the office Mac, with or without a screen). The **viewer** is the Mac you sit at. The first launch asks which one this Mac is; you can switch later with the *Host / Viewer* toggle at the top of the window.

![First launch: choose whether this Mac is the host or the viewer](images/welcome.png)

## Requirements

- Two Macs on **macOS 14 or later**.
- A network path between them: the same LAN, or both on the same [Tailscale](https://tailscale.com) tailnet. Over Tailscale no port forwarding is needed.
- To build: the Xcode Command Line Tools and [Homebrew](https://brew.sh) (for `livekit-server`). Xcode itself is not needed.

## Install

There is no download yet. Build the app from source:

```sh
git clone https://github.com/estruyf/teleport.git && cd teleport
npm run deps      # brew install livekit; it is bundled into the app at build time
npm run bundle    # swift build + build/Teleport.app
open build/Teleport.app
```

For the other Mac, `npm run dist` builds a release zip in `dist/`. With a notary profile set up it is notarized and stapled, so Gatekeeper accepts it without right-click tricks; see [development](development.md#release-builds).

## Set up the host

1. Open Teleport and choose **Share this Mac's apps**. The host lives in the menu bar; closing the window keeps it running, and the menu bar item reopens it.
2. Grant **Screen Recording** and **Accessibility** when asked. The window shows a notice with a button to System Settings while either is missing.
   - Without Screen Recording nothing can be streamed. After you switch it on, macOS offers *Quit & Reopen*. That's normal.
   - Without Accessibility viewers can see windows but not click or type.
3. Under **Apps to teleport**, press *Add app* and search the installed apps, or drop an `.app` on the sheet. Nothing is shared until you add apps; viewers only see windows of these apps.

![Host window: hosting status, a pairing code, paired Macs and the apps to teleport](images/host.png)

The hero card shows the addresses viewers can use (the Tailscale address first) and the port.

### Keep the host reachable

The *Keep it running* card has the settings that matter for an office Mac nobody sits at:

- **Start Teleport when this Mac logs in** registers a login item, so a reboot comes back hosting on its own.
- **Keep this Mac from locking itself** is for a Mac that locks after some idle minutes (its own settings or a company policy). While hosting, Teleport counts as someone using it. It can't unlock a Mac that is already locked.
- **After a restart** checks how the Mac signs in. Teleport runs for whoever is signed in, so it needs automatic login to your account, or a sign-in through Screen Sharing. With FileVault on, a restart stops at the disk password before macOS starts; someone has to type it, or restart with `sudo fdesetup authrestart`, which skips it once.
- **Stay unlocked after Screen Sharing.** If you sign in through Screen Sharing, closing it locks the Mac again, and a locked Mac takes no typing. This switch sets macOS's `RestoreMachineState` to keep it unlocked (asks for an admin password). It outlives Teleport, so Teleport offers to switch it back when you quit.

When the host is locked, viewers see a warning: windows still show, but typing and opening new windows won't work until it is unlocked.

### A headless host

With no monitor attached, the host creates a virtual Retina display ("Teleport Stage") so windows have somewhere sharp to render. Its size is in `virtualDisplay` in [`config.json`](configuration.md#configjson). If it misbehaves, an HDMI dummy plug is the fallback.

## Set up the viewer

1. Open Teleport and choose **Use apps from another Mac**.
2. Press **Pair a new Mac**. Hosts on the same network or tailnet are listed by name; otherwise type the address shown on the host.
3. On the host, press **Show pairing code**. Type the 6-digit code on the viewer within two minutes.
4. The host asks whether to allow the viewer. Both Macs show the same fingerprint; if they differ, press *Deny*. After *Allow* the viewer is paired for good, until you revoke it on the host.
5. Press **Open portal** to connect.

Once connected, the viewer lists the host's shared apps with their windows. Click a window to open it as a portal, or use *Launch*, *New window* and *Quit* (Option turns Quit into Force Quit). The same actions are in the menu bar item.

![Viewer window: connected to the office Mac, with its shared apps and their windows](images/viewer.png)

## Using portals

- A portal is a native window with a teal border and a *Remote* badge, titled `<window> – Remote · <host>`. Each remote app gets its own Dock icon, named after the app.
- Keyboard, mouse, scroll and resize go to the host window.
- Copied text syncs both ways (up to 14 KB). Turn it off with `clipboardSync` in [`config.json`](configuration.md#configjson).
- Drop a file on a portal to send it to the host; it lands in `~/Downloads/Teleport/` there. This is experimental.
- If the connection drops, the viewer keeps trying for two minutes and reopens its portals.

## Try it on one Mac

You can run a host and a viewer side by side on one Mac. The second instance gets its own identity and settings through `TELEPORT_HOME`:

```sh
npm run start:loopback-host   # a second instance as host, with its own identity in ~/.teleport-host
open -n build/Teleport.app    # the viewer; pair with 127.0.0.1
```

Granting Screen Recording makes macOS offer *Quit & Reopen*. That quits every instance of the app and relaunches one without `TELEPORT_HOME`, so start the loopback host again afterwards.

## Troubleshooting

| Problem | What to do |
|---|---|
| "livekit-server not found" on the host | Rebuild after `npm run deps`, or `brew install livekit` on the host. |
| Viewer: "… no longer knows this Mac" | The host revoked it or lost `trust.json`. Pair again. |
| Viewer: "Can't reach …" | Check that Teleport is hosting on the other Mac and that ports 7880–7883 are reachable (or use Tailscale). |
| Windows show but typing does nothing | The host is locked, or Accessibility is off. See [keep the host reachable](#keep-the-host-reachable). |
| Video looks soft or stutters | See [video quality](video-quality.md). |

Logs are in `~/.teleport/app.log` (`npm run logs`); the [configuration doc](configuration.md#files) lists the others.
