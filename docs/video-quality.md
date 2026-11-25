# Video speed and sharpness

How to measure the video path, the settings that change it, and what is known about each of them. The ideas come from [voxl](https://github.com/tembo/voxl): paint-over, frame rate before quality, no jitter buffer, and measuring everything. Its code is not used; a voxl binary is GPL because it links x264.

Video path: ScreenCaptureKit → LiveKit `BufferCapturer` → WebRTC (VideoToolbox H.264) → livekit-server on the host → viewer. Host side: `Sources/Teleport/Host/Portal.swift`.

## Settings

All of them live in a `video` section of `~/.teleport/config.json` (`~/.teleport-host/config.json` for a loopback host). Every key is optional; leaving one out keeps what Teleport did before. A value that doesn't parse, or a key Teleport doesn't know, is logged as a warning in `app.log` and ignored. It never costs you the config.

**Quit Teleport before editing.** The running app writes `config.json` back from memory, so edits made while it runs are lost. `app.log` shows a `video: …` line with the settings each run actually used.

| Key | Side | Default | What it does |
|---|---|---|---|
| `stats` | both | `false` | One line a second per portal in `stats.log` (see below). Turn this on first; everything else is judged by it. |
| `codec` | host | `"h264"` | `"h265"` publishes HEVC. If the SFU or viewer won't take it, WebRTC falls back to the next codec it offers. That may not be H.264; the stats line shows which one ran. |
| `degradation` | host | `"maintainResolution"` | `"maintainFramerateAndResolution"` stops WebRTC from dropping frame rate (or resolution) under pressure, so quality (QP) gives instead. |
| `maxBitrateKbps` | host | `25000` | Ceiling for a portal's bitrate. Screen shares start at 90% of it. |
| `playoutDelayMs` | host | unset | Pins the viewer's playout delay (jitter buffer) to this many ms. `0` asks the viewer to render each frame as soon as it is decoded. Takes effect when hosting starts (the room is created then). |
| `encoder` | host | `"webrtc"` | `"teleport"` encodes with Teleport's own VideoToolbox session instead of the SDK's. Read at launch: quit and reopen after changing it. |
| `prioritizeSpeed` | host | `true` | Teleport encoder only: `PrioritizeEncodingSpeedOverQuality`. Roughly doubles HEVC's speed at a big cost in quality; H.264 ignores it (see measurements). |
| `paintOver` | host | `false` | Once the window stops moving, re-sends the last frame a few times, encoded sharper. Implies `encoder: "teleport"`. |
| `paintOverDelayMs` | host | `150` | Stillness before a paint-over. |
| `paintOverFrames` | host | `3` | Frames per paint-over, two frame times apart. |
| `paintOverMaxQP` | host | `22` | QP ceiling for paint-over frames (0–51, lower is sharper and bigger). VideoToolbox treats it as a target, not a hard limit. |
| `paintOverBitrateBoost` | host | `4` | Paint-over frames may use this multiple of WebRTC's bitrate target. |
| `motionMinArea` | host | `0.01` | Share of the window that must change for a frame to count as motion. A caret or a spinner stays below it: it doesn't hold a paint-over back, and repaints at most once a second. |
| `probe` | viewer | `false` | Reads TeleportTestPattern's stamps from decoded frames and logs latency and frame rate (see harness). |
| `probeClockCorrectionMs` | viewer | measured | Added to every latency the probe reports. Unset, the viewer measures the host's clock itself; set it only to override that. |

Example, host and viewer both logging, the host trying HEVC with no jitter buffer:

```json
"video": { "stats": true, "codec": "h265", "playoutDelayMs": 0 }
```

## Running an A/B test

1. Quit Teleport on both Macs. Set `"stats": true` on both, and `"probe": true` on the viewer.
2. Set the variant on the host. Start both, connect, open the test pattern (below).
3. Run each mode (keys 2, 3, 4, then 1) for 30 seconds.
4. Keep the `probe-summary` lines from the viewer and the `host`/`encoder` lines from the host: `grep -E "probe-summary|probe-clock" ~/.teleport/stats.log | tail -12`.
5. Change one key, repeat. Compare worst-second fps, p50/p99 latency, average QP and kbps.

## stats.log

`npm run logs:stats` follows it (set `TELEPORT_HOME` for a loopback host's). It rotates at 10 MB, keeping three old files. Every value covers the last second only.

| Line | Fields |
|---|---|
| `host win=…` | codec (and the H.264 `profile-level-id` negotiated), `enc` encoder implementation, size, `fps` frames encoded, `kbps` sent, `target` WebRTC's bitrate target, `bwe` estimated bandwidth, `qp` average QP, `limit` quality limitation (`none`/`cpu`/`bandwidth`), `enc_ms` encode time per frame, `key`, `pli`, `nack`, `rtt`; with paint-over, `cap_motion`/`cap_change`/`cap_paintover` frames by kind |
| `encoder …` | Teleport encoder only: frames, kbps, target, `paintover` frames/KB, `vt_drops` frames VideoToolbox dropped, `vt_ms` submit-to-output time |
| `viewer win=…` | codec, `dec` decoder, size, `fps` decoded, `kbps`, `qp`, `dropped`, `jb_ms` jitter-buffer wait per frame, `dec_ms`, `proc_ms` first packet to decoded, `key`, `lost`, `freezes`, `rtt` |
| `probe win=…` | `mode`, `fps` new stamps, `repeats` (refreshes, paint-overs), `missed` stamps drawn but never decoded, `unreadable`, `lat_p50/p99/max` ms |
| `probe-summary win=…` | every 10 s, over the seconds in the current mode: `worst_fps`, `mean_fps`, `missed`, latency percentiles |
| `probe-clock win=…` | `host_ahead_ms`, and `within_ms`: the bound on that measurement |

`qp` shows `-` when WebRTC reports no QP for the stream; the Teleport encoder leaves QP to WebRTC's own bitstream parser (see open questions).

## Measurement harness

**TeleportTestPattern** runs on the host. Every refresh it stamps a frame counter, the wall-clock time and its mode into a block pattern in its top-left corner. Keys switch modes, typed on the viewer through the portal too:

| Key | Mode | Shows |
|---|---|---|
| 1 | idle | nothing moves; the stamp ticks once a second (paint-over, keep-alive refreshes) |
| 2 | text | a page of code scrolling 4 pt a frame |
| 3 | drag | a detailed panel sliding over a busy background, like a dragged window |
| 4 | animation | every pixel changes every frame |

The **probe** (`video.probe` on the viewer) reads the stamp from every decoded frame. It measures from the host drawing a frame to the viewer decoding it: capture, encode, network, jitter buffer, decode. Neither display is included, so true glass-to-glass is about one refresh (≈17 ms) more on each end. The worst second's fps counts new stamps only; a second with no frame counts as 0.

Checks that run without Teleport:
- `.build/debug/TeleportTestPattern --self-check` draws each mode offscreen and reads the stamp back.
- `Teleport --encoder-selftest` (below) encodes stamped frames and reads them back after decoding; they survive 1 Mbps at 3840×2400.

### Loopback (one Mac, one clock)

```sh
npm run bundle
npm run test-pattern                 # builds and opens build/Teleport Test Pattern.app
# Quit Teleport. Add "video": {"stats": true} to ~/.teleport-host/config.json
# and "video": {"stats": true, "probe": true} to ~/.teleport/config.json.
npm run start:loopback-host          # host; add "Teleport Test Pattern" under Shared apps
open -n build/Teleport.app           # viewer; connect, open the Teleport Test Pattern window
tail -F ~/.teleport/stats.log | grep probe
```

Host and viewer share the CPU, GPU and media engine here, so the numbers are worse than two Macs would show. Use it to check that the harness works and to compare settings, not for absolute latency.

### Two Macs

1. On the host (office Mac, in its clone): `git pull && npm run bundle && scripts/test-pattern.sh`. Copy the bundle into place with `cp -R "build/Teleport Test Pattern.app" /Applications/`.
2. On both Macs, quit Teleport and add the `video` section: host `{"stats": true}` plus the variant; viewer `{"stats": true, "probe": true}`. Start both.
3. On the host, add *Teleport Test Pattern* under *Shared apps*. That can be done over Screen Sharing; after that nothing on the host needs a screen.
4. On the viewer, connect, then *Launch* Teleport Test Pattern and open its window. Leave the portal at the size it opens with, so the stream stays at native size.
5. Click into the portal and press 2, 3, 4 and 1, 30 seconds each. Watch `tail -F ~/.teleport/stats.log | grep probe` on the viewer and `npm run logs:stats` on the host.
6. The viewer measures the host's clock offset when the portal opens (`probe-clock` line, error at most half a LAN round trip, about 1 ms). Over Tailscale or Wi-Fi, check that `within_ms` is small next to the latencies.
7. Save the summaries: `grep -E "probe-summary|probe-clock" ~/.teleport/stats.log > ~/Desktop/run-<variant>.txt`, and the host's `host`/`encoder` lines likewise.

## What is verified and what is assumed

Verified means read in the source of the version we ship, or measured on this Mac (M2 Pro, macOS 26.6, VideoToolbox from the 15.5 SDK). Nothing below ran end to end between two Macs; that is the next step (the A/B list at the end).

**livekit-server and H.265** (bundled 1.13.11):
- Verified: `video/h265` is in the default `room.enabled_codecs` (`pkg/config/config.go`).
- Verified: the bundled WebRTC framework has `RTCVideoEncoderH265` and `RTCVideoDecoderH265`.
- Not verified: an H.265 publish through the SFU to a subscriber. If it doesn't negotiate, the codec WebRTC falls back to may be VP8 (software, slow at this size); the `host` line's codec field shows it.

**Playout delay**:
- Verified in the source: the token's `roomConfig` is applied only by the join that creates the room (`RoomManager.getOrCreateRoom` returns an existing room as it is). The host's own join creates it, so a viewer token's `roomConfig` alone does nothing. Teleport puts it in every token, the host's included.
- Verified: the token can't express 0. `RoomAllocator.CreateRoom` enables the delay only when min or max is above 0. Teleport therefore also writes `room.playout_delay {enabled, min, max}` into `livekit.yaml`; livekit-server 1.13.11 starts with it.
- Verified: the SFU sends the playout-delay RTP header extension with min = clamp(jitter × 10, min, max) and max = max, so min = max pins it.
- Assumed: the Swift SDK's WebRTC negotiates that extension on the subscriber side and renders right away at min = max = 0. `jb_ms` on the viewer line shows whether it did.

**VideoToolbox QP controls** (`scripts/vt-probe.swift`, `Teleport --encoder-selftest`):
- Verified: `MaxAllowedFrameQP` and `MinAllowedFrameQP` are accepted by the hardware H.264 and HEVC encoders in the default rate control.
- Verified: on its own, a QP ceiling barely changes the picture, because the bitrate cap still binds. A ceiling plus a raised bitrate does (numbers below). Even then the ceiling is not a guarantee: a cap of 22 left HEVC at 8 Mbps far below what QP 22 looks like.
- Verified: `SupportsBaseFrameQP` (per-frame QP, i.e. your own rate control) is false in the default rate control and true only in low-latency mode. Low-latency mode dropped most frames at 3840×2400 here (all of them for H.264).
- Verified: there is no per-region QP API in VideoToolbox (no QP map or ROI in the headers). Voxl's region sharpening can't be done on the hardware encoder.
- Not verified: whether a setting change ever lands on the wrong frame when WebRTC pipelines frames. The encoder flushes the session when paint-over starts or ends, to be safe; that costs at most one encode time on the first frame after a paint-over.

**H.264 levels at 3840×2400@60**:
- Verified (arithmetic): 3840×2400 is 240×150 = 36,000 macroblocks a frame, inside level 5.2's 36,864, but 60 fps makes 2,160,000 macroblocks a second, above 5.2's 2,073,600. It needs level 6.0.
- Verified: VideoToolbox refuses explicit levels 3.1 and 5.2 at this size and rate (`-12902`, no output). AutoLevel writes High@6.0, and the viewer's VideoToolbox decodes it.
- Verified: the bundled WebRTC advertises H.264 only as `640c1f`/`42e01f` (level 3.1), and its Objective-C level enum ends at 5.2. The SDK's encoder plainly runs today, so it doesn't pass 3.1 to VideoToolbox literally.
- Not verified: how the SDK's encoder picks its level and expected frame rate. If it derives the frame rate from the level, its rate control is skewed at this size. Teleport's encoder sets AutoLevel and the real frame rate.

**Encode speed** (synthetic text, one frame every 1/60 s, M2 Pro):

| Size | H.264 | HEVC | HEVC, speed priority |
|---|---|---|---|
| 3840×2400 | ≈25 fps (22 ms a frame) | ≈24 fps | ≈45 fps (13 ms a frame) |
| 2560×1600 | ≈54 fps (11 ms) | ≈51 fps | 60 fps (7 ms) |

`PrioritizeEncodingSpeedOverQuality` changes nothing for H.264. A full-screen 3840×2400 window at 60 fps is out of reach for H.264 on this chip, whatever the settings: the encoder, not the network, would cap it. The host Mac may differ; run `swiftc -O scripts/vt-probe.swift -o /tmp/vt-probe && /tmp/vt-probe 25000` there.

**Paint-over**:

`Teleport --encoder-selftest h264|h265 [kbps]` runs Teleport's encoder as WebRTC does: 30 frames of scrolling, then the still picture 8 times. One column uses today's plain repeats, the other a 3-frame paint-over. It decodes everything and compares luma PSNR with the source. Synthetic text at 3840×2400, harsher than real text:

| | today's repeats | paint-over | bytes, repeats → paint-over |
|---|---|---|---|
| H.264, 8 Mbps | 34.3 dB | 35.4 dB | 213 → 410 KB |
| H.264, 25 Mbps | 44.5 dB | 45.9 dB | 340 → 643 KB |
| HEVC, 8 Mbps, speed priority | 22.5 dB | 25.1 dB | 71 → 496 KB |
| HEVC, 25 Mbps, speed priority | 29.4 dB | 34.0 dB | 180 → 962 KB |
| HEVC, 8 Mbps | 30.8 dB | 33.7 dB | 110 → 428 KB |
| HEVC, 25 Mbps | 40.0 dB | 45.4 dB | 8 → 657 KB |

Plain repeats do sharpen a little through this encoder. Whether they do through the SDK's encoder (today's default) is not measured. Not verified at all: paint-over through WebRTC to a real viewer, the dirty-rect units (the first three frames of each portal are logged in `app.log` to check), and WebRTC's own frame dropper after a large paint-over frame.

## Paint-over: design and open questions

How it works now:
- `FrameOutput` sizes each frame's `dirtyRects` against the frame: at least `motionMinArea` is motion, less is a small change.
- `paintOverDelayMs` after the last motion, it re-sends the last buffer `paintOverFrames` times, two frame times apart, tagged as paint-over. Small changes alone trigger at most one paint-over a second; motion during a burst cancels it.
- The tag rides on the `CVPixelBuffer` as an attachment: WebRTC hands the encoder the same buffer (`VideoCapturer.capture` wraps it without copying).
- `TeleportEncoder` gives tagged frames `paintOverMaxQP` and `paintOverBitrateBoost` × the target. After a keyframe, the next keep-alive refreshes are sharpened too.

Open questions, roughly in the order they matter:
1. **Burst cost against latency.** A paint-over is 0.4–1 MB: 130–320 ms of a 25 Mbps link. Motion that resumes in that window waits behind it. Voxl bounds this with x264's VBV; here only the boost factor bounds it. Measure with drag mode: stop, start again, and watch `lat_max`. Lower the boost or the frames if it spikes.
2. **Per-frame QP.** True voxl-style rate control (a QP picked per frame) needs `BaseFrameQP`, which only low-latency mode offers, and that mode dropped most frames at this size. Worth one more probe at the host's real window sizes and bitrates before giving up on it.
3. **Region sharpening is impossible on VideoToolbox.** A small spinner doesn't block paint-over (it repaints the whole frame once a second). A video playing in a corner bigger than `motionMinArea` does block it. A software encoder with ROI would be needed; x264 is GPL, so it would have to be another.
4. **QP in stats.** The Teleport encoder reports no QP and relies on WebRTC parsing it from the bitstream. If the `host` line shows `qp=-` with `enc=Teleport/VideoToolbox`, the next step is parsing the slice QP in `AnnexB`.
5. **A new viewer waits for sharpness.** A keyframe for a new viewer is sharpened by the next keep-alive refreshes, one a second, so up to 3 s.

## First A/B tests on the two Macs

Run each against the plain baseline (`{"stats": true}` on the host), all four test-pattern modes:

1. **`"codec": "h265"`.** Check whether the host's `fps` and `enc_ms` at full window size are encoder-bound with H.264 (`limit=cpu`, fps near 25), as on this M2 Pro. This is likely the biggest win.
2. **`"codec": "h265", "encoder": "teleport"`** (speed priority on), then the same with `"prioritizeSpeed": false`. The trade-off between frame rate and sharpness.
3. **`"playoutDelayMs": 0`.** Viewer `jb_ms` and probe p50/p99 against unset.
4. **`"paintOver": true`** (H.264, then H.265). Idle and text after scrolling stops: sharpness by eye and `qp`; drag mode for latency spikes when motion resumes.
5. **`"degradation": "maintainFramerateAndResolution"` with `"maxBitrateKbps": 8000`.** Frame rate under bandwidth pressure.

If none of these reaches 60 fps at full size, the next thing to test is the virtual display's resolution (`virtualDisplay` in the config). It is not a `video` key, but it decides how many pixels each frame has.
