# Security notes

What protects a Teleport host, and what doesn't yet. Whoever controls a viewer can type into the host's apps, so a paired viewer is treated like an SSH key: pairing needs a person at both Macs, every connection is authenticated, and the host decides which apps are reachable.

## The model today

| Piece | How |
|---|---|
| Identity | Each Mac has an X25519 key in `~/.teleport/device.key` (mode 600). The public key is the device id. |
| Pairing | The host shows a one-time 6-digit code (2 minutes). The viewer derives a key from X25519 agreement **and the code** (HKDF, the code as salt) and sends its name sealed with ChaCha20-Poly1305. The code itself never travels. A request only opens on the host whose code was typed. 5 wrong tries close pairing; one pending request at a time. |
| Allow | The host shows the viewer's name and a 6-digit fingerprint of the shared key; the viewer shows the same. A man-in-the-middle produces different digits. Nothing is stored until Allow; Deny or 60 seconds throw it away. |
| Trust | `trust.json` on the host: name and public key of each allowed viewer. Revoke removes it and kicks a live session. `hosts.json` on the viewer: name, address, host key. |
| Session | The viewer asks the host's control endpoint (port+3) for a LiveKit token: timestamp and nonce sealed with the agreement-only key. Timestamp within 60 s, nonce single-use. Tokens last one hour; LiveKit refreshes them while connected. The LiveKit secret never leaves the host. |
| Apps | The allow-list is enforced on `apps`, `open` and `launch`. Nothing is shared until an app is added. |
| Input | Only room participants can send input, and only paired viewers get tokens. |
| Files | Dropped files land in `~/Downloads/Teleport/<basename>`; the name is reduced to its last path component. |
| Media | WebRTC media is DTLS-SRTP encrypted end to end. |

## Known gaps (do before trusting an untrusted LAN)

1. **Signalling is plain `ws://`.** On a hostile LAN a sniffer can read the LiveKit token from the WebSocket and join the room for up to an hour. Over Tailscale the whole path is inside WireGuard, so the office-to-home case is covered today.
   *Fix:* a self-signed TLS proxy on the host in front of LiveKit. During pairing the host hands over its certificate fingerprint signed with its device key; the viewer pins it and refuses anything else. Even "TLS off" should be a signed notice, so a pinned viewer knows it was the host's choice.
2. **Pairing lockout is per process.** 5 wrong codes close pairing, but a restart resets the counter and there is no per-address backoff. *Fix:* a lockout window ("too many wrong codes recently, pairing is locked for a while") and backoff per client address.
3. **Nonces live in memory.** A token request replayed after a host restart within its 60 s window would be accepted. *Fix:* persist recent nonces, or sign the host's start time into the challenge.
4. **The host trusts the room, not the sender.** Input and file streams are accepted from any participant. Today only paired viewers hold tokens, so this is fine; once guest or browser viewers exist, check the sender identity against `trust.json` per message, and give view-only tokens `canPublishData: false`.
5. **Control endpoint on every interface.** Pairing and token requests are accepted from any address that reaches port+3. *Fix:* bind to LAN and tailnet interfaces only, and rate-limit.
6. **Keys on disk.** `device.key` and the host's LiveKit secret are files with mode 600. Good enough for a personal Mac; the Keychain (or `safeStorage`-style encryption, as Seshboard does for the engine key) would survive a copied home folder better.
7. **Logs** record window titles and app names. Keep them out of bug reports you share.
8. **Private APIs.** The virtual display and `_AXUIElementGetWindow` are undocumented. They can break on a macOS update; that's a reliability risk, not a security one.

## Checklist for a release on an untrusted network

- [ ] TLS proxy with signed, pinned fingerprint
- [ ] Pairing lockout window and per-address backoff
- [ ] Persistent nonces or a host-epoch in the challenge
- [ ] Sender check on input and file streams
- [ ] Control endpoint bound to LAN and tailnet interfaces, rate-limited
- [ ] Keys in the Keychain
