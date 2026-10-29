# First release

What is still missing for a 0.1 that Elio can put on the office Mac and use every day. Ordered: blockers first.

## Must

- [ ] **Real two-Mac test.** Everything so far ran on one Mac. On the headless office Mac: the virtual display appears and gets its Retina mode, windows move onto it, capture is sharp, clicks land where they were aimed, resize follows, Launch and New window work for VS Code, Edge, Chrome, Terminal, Ghostty, Seshboard. Fallback if the Stage misbehaves: an HDMI dummy plug.
- [ ] **Popups and menus.** Confirm dropdowns, context menus and autocomplete show up in portals (the app-wide capture cropped to the window is meant to carry them). The menu bar of a remote app is not in the window; decide whether to live with shortcuts or add a menu strip later.
- [ ] **Keyboard edge cases.** Belgian/US layouts, dead keys, Fn and media keys, ⌘Tab and ⌘Space staying local, modifier state after focus changes.
- [ ] **Reconnect.** Viewer reconnects when the host restarts or the network blips; host restarts `livekit-server` if it dies; portals reopen or close cleanly.
- [ ] **Host starts at login and survives.** A LaunchAgent for the host Mac (RunAtLoad, KeepAlive), hosting on by default, so a reboot of the office Mac needs no SSH. A watchdog like Beam's is a bonus.
- [ ] **Bundle `livekit-server`.** Download a pinned release (with checksum) into `Contents/MacOS` in `scripts/bundle.sh`, so the office Mac needs no Homebrew. Keep the `livekitServerPath` override.
- [ ] **Release build, notarized.** `scripts/bundle.sh release`, `notarytool` with the Developer ID, stapled, zipped. Gatekeeper then accepts the copy on the office Mac without right-click tricks. Entitlements already cover the hardened runtime.
- [ ] **Plain-words errors.** Viewer: "not paired any more, pair again" on 401, "host unreachable, is Teleport running there?" on connection failures, token expired. Host: "livekit-server not found" with what to do; a note that Screen Recording needs Quit & Reopen.
- [ ] **Commit and tag.** The work since the initial commit is uncommitted. Add a LICENSE, tag `v0.1.0`, merge the office Mac's clone.

## Should

- [ ] **Discovery.** Bonjour `_teleport._tcp` on the LAN and the Tailscale machine list (`/localapi/v0/status`) so the pair sheet offers hosts by name instead of an address.
- [ ] **Tests and CI.** Unit tests for `PairingCrypto` (seal/open, wrong code fails, fingerprint stable), `AccessToken`, the control endpoint's refusals; a GitHub Actions macOS job running `swift build` and `swift test`.
- [ ] **Log rotation** at 10 MB, and a `teleport report` style zip for bug reports.
- [ ] **Clipboard sync**, both directions, text first.
- [ ] **Security hardening** from [security.md](security.md): at least the TLS proxy before using a plain LAN you don't control.
- [ ] **Dock tile polish.** Confirm the stub's icon and name show reliably, bouncing and badge, and that tiles vanish when the viewer quits.
- [ ] **Updates.** Sparkle with an appcast, as Beam does, once there is a place to host releases.

## Later

- Audio of the remote app, HEVC 4:4:4 "text clarity", file drag from host to viewer, multiple viewers, a browser guest viewer, a `teleport` CLI (`doctor`, `pair`, `serve`) for SSH use.
