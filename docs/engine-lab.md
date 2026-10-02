# Engine lab

The engine lab runs a corpus of difficult media through the engine headless on macOS, measures each source, and writes a scoreboard. It is how a change to the engine is judged against the media it has to survive, Infuse-style: run the lab, fix the worst offenders, run it again, and read the delta.

It has three parts:

| part | where | what |
|---|---|---|
| `aetherctl lab` | `Sources/aetherctl/LabCmd.swift` | one measurement of one source, as JSON |
| runner | `Scripts/engine-lab/lab.py` | corpus → `aetherctl lab` per source → ffprobe oracle → scoring → scoreboard + delta |
| corpus | `Scripts/engine-lab/corpus.json`, `fetch_corpus.py` | the manifest, plus a fetcher/generator for public and generated media |
| debrid quirks | `Scripts/engine-lab/quirk_server.py` | an HTTP origin that misbehaves the way debrid / CDN links do |

No media is committed. The corpus lives on the internal disk at `~/Developer/openstream-build/engine-lab/corpus` (`ENGINE_LAB_CORPUS` overrides it). Runs go to `~/Developer/openstream-build/engine-lab/runs/<stamp>-<label>/` (`ENGINE_LAB_HOME` overrides the parent). The fetcher stops at 40 GB. The current corpus is about 4.4 GB.

## Running it

```bash
swift build --product aetherctl                       # the lab uses the debug aetherctl
python3 Scripts/engine-lab/fetch_corpus.py            # download + generate (cached; --force to redo, --only id,id)
python3 Scripts/engine-lab/lab.py run --label baseline
python3 Scripts/engine-lab/lab.py run --label fix-x --only q-range-ignored,g-mkv-nocues   # re-run a subset
python3 Scripts/engine-lab/lab.py compare runs/<A> runs/<B>                              # before/after table
python3 Scripts/engine-lab/lab.py rescore runs/<A>                                       # re-apply edited thresholds
```

`--aetherctl PATH` points at a different binary. The default is `~/Developer/openstream-build/aether-fork-spm/debug/aetherctl`, the scratch path this fork builds into. `--seconds N` sets the play window (default 6).

Each run writes:

- `results/<id>.json`: the engine's measurement, the ffprobe oracle, per-metric scores and the reason for each failure.
- `logs/<id>.log`: stdout of that aetherctl process.
- `scoreboard.md`: pass rate per metric, worst offenders first, every source in one table, oracle notes, and the delta against the previous run (or `--baseline`).
- `summary.json`: the machine-readable version.

`runs/latest` points at the newest run.

One source can be measured by hand:

```bash
aetherctl lab [--seconds 6] [--sw] [--native-hls] [--live] [--no-seeks] [--verbose] [--out r.json] <url-or-path>
```

The engine is muted (`volume = 0`): a lab run never makes a sound. URLs are redacted out of everything the harness records (`<url>`), so a scoreboard built against a tokenised origin can be pasted into an issue.

## What is measured

Every source runs in its own `aetherctl` process. A crash or a wedge costs that row, not the run, and the memory peak belongs to that session.

| step | measured |
|---|---|
| open | `load()` success, wall time, `PlaybackErrorInfo.kind` + message on failure, a 45 s timeout reported as `timeout` |
| probe | container, video codec, size, fps, DV profile, source / output video format, every audio track (codec, channels, language) and subtitle track |
| route | `videoRoute` (loopback / remoteBypass / software / audio), backend, the video and audio decoder labels, audio delivery |
| first frame | load call → first **presented** frame, plus the engine's own `hasFirstFrameReadyForDisplay` edge |
| play window | 6 s of playback: clock advance, buffering samples, presented frame count and rate, PTS gaps (missing frames), freezes, backwards PTS, engine dropped-frame counter, early end of media |
| seeks | 50 %, 90 %, 10 % (in that order, so each landing is far from the previous playhead). For each seek: `seek()` return time, seek-to-**frame** latency, the engine's terminal `SeekEvent`, clock at landing vs target, and 3 s of continuity after the landing (how long the landing frame stays up, freezes, PTS gaps, black flash, display starvation on the software route) |
| drift | clock rate against wall time, presented video against the clock over the steady part of the window, and the engine's producer A/V gate gap (`LiveTelemetry.avSyncGapMs`, loopback only) |
| memory | peak `phys_footprint` sampled at 20 Hz across the whole session |

How frames are observed without a screen:

- **Native routes (loopback, remote bypass).** An `AVPlayerItemVideoOutput` (8-bit 4:2:0) is attached to the engine's `currentAVPlayerItem` and re-attached whenever the engine swaps the item. It is polled at 250 Hz. Every presented frame is recorded with its item PTS, wall time and mean luma on a 16×9 grid. The attached output is also what makes AVPlayer decode and present without a layer in a window.
- **Software route.** The engine's `setSoftwareVideoFrameTimeObserver` reports every frame the host enqueues (PTS + decode generation). The presentation timebase is polled at 100 Hz, and a timebase that runs more than two frames past the last enqueued frame is counted as **display starvation**. That is the software-route freeze the enqueue stream alone cannot show.

The seek landing frame is the first frame after the seek call that is more than 0.5 s from the pre-seek playhead (software: of a newer decode generation). Failing that, it is the first frame that arrives after `seek()` returned. "Black flash" means a frame with mean luma < 0.06 within 500 ms of the landing, in a window whose picture settles above 0.15 after one second. That is the Strand-style "black frame / stutter after seek" report expressed as a number.

### The ffprobe oracle

`ffprobe` (Homebrew FFmpeg) is run on the same source, and on the same quirk-server behaviour with its own request counter. The oracle **fails** a row when ffprobe opens the source and the engine does not, when the first video codec differs, or when the DV profile differs. Different audio or subtitle track counts, or a duration off by more than 5 % / 2 s, are only notes: the engine hides tracks it cannot deliver on purpose, and remote HLS has no track list on the bypass.

## Thresholds

They are set in `THRESHOLDS` at the top of `lab.py`. Edit them there and `rescore` an old run to see the effect.

| metric | passes when |
|---|---|
| crash | aetherctl produced a result (no crash, no 180 s process timeout) |
| open | opened within 5 s local / 12 s remote or quirk (+8 s for the slow-first-byte quirk). A `clean-fail` source must FAIL within 15 s and not by timeout. A `no-wedge` source may fail, but not by timeout |
| oracle | see above |
| ttff | first presented frame within 2.5 s local / 6 s remote (+8 s slow-first-byte) |
| playback | no state error, clock advanced ≥ 80 % of (window − 1 s), no end of media more than 2 s before the source's duration |
| frames | missing frames ≤ 2 % of presented, no freeze (a hole > max(250 ms, 4 frames)), no display starvation |
| seek_latency | every seek lands. Frame latency ≤ 1.5 s local / 3 s remote. Landing within 2 s of the target |
| seek_continuity | after every landing: the landing frame is held ≤ 250 ms, no freeze, no PTS gap, no black flash, no backwards PTS, no display starvation |
| av_drift | presented video vs clock ≤ 100 ms over the window, engine A/V gate gap ≤ 100 ms, clock rate within 3 % of wall time |
| memory | peak footprint ≤ 700 MB (≤ 1080p) / 1400 MB (UHD) |

Sources of 10 s or shorter skip the seeks (targets are clamped to end 5.5 s before the end, because reaching end of media ends the session). Live sources skip them too.

Muse research (notes 26/27, unverified) suggests tighter targets: A/V ≤ 40 ms nominal / 80 ms after a seek, and time to first frame < 3 s for a 70 GB DV P7 MKV over SMB. Our presented-vs-clock number is quantised to one 100 ms sample of the frame stream, so 100 ms is the honest floor for now.

## Corpus

`python3 Scripts/engine-lab/fetch_corpus.py --list` prints every entry. The categories are:

| category | contents |
|---|---|
| dolby-vision | Jellyfin DV P5 / P8.1 / P8.4 (1080p, 4K P8.1) MP4, the P8.1 remuxed to MKV with mkvmerge |
| hdr | HDR10 HEVC + AV1 (1080p, 4K), an HDR10 4K MKV head (FFmpeg samples), generated HDR10 (mastering display + CLL SEI) and HDR10+ (ST 2094-40 per frame) HEVC |
| video-codecs | AVC / HEVC 8-bit / HEVC 10-bit / AV1 1080p, AV1 4K, HEVC 8K; generated H.264 High10, HEVC Main10 `hvc1` vs `hev1` (in-band parameter sets), AV1 (SVT) + Opus MKV, VP9 + Opus WebM; VC-1 MKV, VC-1 + TrueHD m2ts, AVI MPEG-4 ASP with two audio tracks |
| interlaced | MPEG-2 interlaced PS (two), H.264 PAFF and MBAFF TS, ATSC 1080i MPEG-2 + AC3 TS, generated MPEG-2 1080i TFF + AC3 TS |
| audio-codecs | TrueHD MKV, DTS-HD MA m2ts, E-AC3 (MKV, MP4 channel check, 7.1 dependent substream m2ts), AAC LATM TS (two broadcast + one generated), generated TrueHD 5.1 / DTS 5.1 / E-AC3 5.1 / FLAC 7.1 / PCM s24 5.1 MOV |
| containers | non-faststart vs faststart MP4, fragmented MP4, AVI XviD + MP3, MKV without Cues, MKV with laced audio, MKV truncated at 70 %, the first 60 MB of Sintel's 1.1 GB MKV, an MP4 edit list, AVI with a broken index, a mid-stream size change, a decode-error-stop MKV, a SimpleBlock edge case |
| timestamps | TS whose 33-bit PTS wraps 23 s in, VFR (24→60→29.97 generated, plus an MPEG-4 VFR sample), 120 fps MKV, an HDTV TS with a seek-bug history |
| subtitles | VobSub (two, one large canvas), ASS RTL, 15 SSA tracks, multi-sub MKV, embedded-ASS problem file, CEA-608/708 TS, PGS m2ts; generated SRT + ASS, PGS beside Sintel, 3 audio + 2 SRT (one forced) |
| blender | Sintel 60 s mezzanine (H.264 + AC3), Tears of Steel 720p MOV |
| dvd | the repo's two authored DVD menu fixture ISOs |
| hls-remote | Apple bipbop advanced fMP4 (default route and `--native-hls` bypass), bipbop 16x9 TS, Apple's DV + Atmos example |
| debrid-quirks | see below |

Sources and licences:

- Jellyfin test videos: <https://repo.jellyfin.org/test-videos/>, CC BY-SA 4.0.
- FFmpeg samples archive: <https://samples.ffmpeg.org/>.
- Blender open movies: <https://download.blender.org/>, CC BY 3.0.
- Apple HLS examples (streamed, not downloaded).

Downloads are range-limited. A file up to 150 MB comes down whole. A larger stream-tolerant container (TS / m2ts / MKV / MPG) is cut with an HTTP Range request (that partial download is itself a case). A large MP4 / MOV is remuxed with `ffmpeg -t N -c copy` straight off the origin.

**Generated media.** Every generated clip derives from the 60 s Sintel mezzanine (`ffmpeg -ss 290 -i Sintel.2010.1080p.mkv -t 60 -c copy`). The exact command for each one is its `cmd` in `corpus.json`, with `{master}` / `{out}` substituted, and `fetch_corpus.py` runs exactly that. A few examples:

```bash
# non-faststart MP4 (moov after mdat): ffmpeg's default without +faststart
ffmpeg -i master.mkv -t 40 -c:v copy -c:a aac -b:a 192k g-mp4-moov-end.mp4
# fragmented MP4
ffmpeg -i master.mkv -t 40 -c:v copy -c:a aac -movflags frag_keyframe+empty_moov+default_base_moof g-fmp4.mp4
# MPEG-TS whose PTS wraps 23 s in
ffmpeg -i master.mkv -t 40 -c:v copy -c:a aac -output_ts_offset 95420 -f mpegts g-ts-wrap.ts
# HEVC Main10 hev1 with in-band VPS/SPS/PPS
ffmpeg -i master.mkv -t 30 -vf format=yuv420p10le -c:v libx265 -tag:v hev1 -x265-params repeat-headers=1 -c:a aac g-hevc-main10-hev1.mp4
# MKV without Cues
mkvmerge --no-cues -o g-mkv-nocues.mkv master.mkv
```

**Known gaps.**

- **Dolby Vision Profile 7** (dual layer). There is no public, legal demo clip. Dolby's vectors are login-gated, and the Muse notes name none either. Drop a P7 remux into the corpus by hand and add a `local` entry.
- **HDR10+ in the wild.** The generated clip carries the SEI on every frame. The sparse IDR-only shape from the Muse notes is not covered yet.
- **E-AC3 JOC (Atmos) in a file.** Only the remote Apple HLS example carries Atmos.

## Debrid-quirk server

`quirk_server.py` serves corpus files at `http://127.0.0.1:<port>/q/<quirk>/<session>/<file>`. `lab.py` starts it on a free port for every run. Each `(quirk, session)` pair has its own request counter, so the engine and the ffprobe oracle never share state. It can also be run standalone (`python3 Scripts/engine-lab/quirk_server.py --port 8765`) and pointed at with `aetherctl play`.

| quirk | behaviour | expectation |
|---|---|---|
| `redirect-chain` | 302 → 307 → 302 (relative and absolute `Location`) → media | play |
| `slow-first-byte` | every response holds its first byte for 7 s | play (budgets +8 s) |
| `403-after-n` | 403 after the first 6 requests (an expired link) | no-wedge: play, or fail cleanly, never hang |
| `range-ignored` | `Range` ignored: 200 + the whole body, no `Accept-Ranges` | play (MP4, moov-at-end MP4, MKV) |
| `drop-mid-stream` | every response is cut after 3 MB and the socket closed | play (MP4, MKV) |
| `wrong-content-type` | media served as `text/html` | play |
| `wrong-content-type-hls` | MP4 served as `application/vnd.apple.mpegurl` | play |
| `html-200` | an HTML "file not found" page with status 200 | clean-fail within 15 s |
| `status-404` | 404 | clean-fail |
| `no-content-length` | chunked, no `Content-Length`, no ranges | play |
| `503-every-3rd` | every 3rd request is 503 with `Retry-After: 1` | play |
| `ua-waf` | 403 when the User-Agent is missing or a tool's (Lavf, curl, python, Go, okhttp, Wget) | play |

## Adding a case

1. Add an entry to `corpus.json`. Each kind takes these fields:
   - `download`: `url` + `file`, optionally `cap_bytes` / `trim`.
   - `generate`: `cmd` + `file`.
   - `remote`: `url`.
   - `local`: `path` (repo-relative).
   - `quirk`: `quirk` + `target` + `expect`.

   `lab_args` passes extra `aetherctl lab` flags (e.g. `["--native-hls"]`).
2. `fetch_corpus.py --only <id>`, then `lab.py run --only <id>`.
3. When the case exposes an engine defect, fix it with a regression test in `Tests/AetherEngineTests`. Re-run the affected rows and paste `lab.py compare` into the commit or PR.

## First runs (2026-10-01)

These two runs used 98 sources. The `after-fixes` run used the engine at `2fe42dd7`.

| metric | baseline | after fixes |
|---|---:|---:|
| crash | 98/98 | 98/98 |
| open | 95/98 | 97/98 |
| oracle | 95/98 | 96/98 |
| ttff | 92/93 | 94/94 |
| playback | 90/93 | 91/94 |
| frames | 80/93 | 82/94 |
| seek_latency | 55/82 | 71/84 |
| seek_continuity | 63/82 | 70/82 |
| av_drift | 82/92 | 78/93 |
| memory | 98/98 | 98/98 |

Two caveats about comparing these runs:

- The harness started counting software-route display starvation from the seek landing (not from the seek call) between the two runs.
- The new seek_continuity failures on the broadcast TS rows are rows whose seeks never landed before. Their continuity is now measured for the first time.
- The av_drift failures on the software route are the presented-vs-clock number sitting at 100-130 ms. That number is measured against frames as they are enqueued, so it needs a presented-frame measure before it is trusted.

Fixes, each with a regression test:

- **Matroska cut slip.** The VOD cutter now gates Matroska plans on presentation time. Every segment of a B-frame MKV carried the next GOP, and seeking into the last segment stalled.
- **Range-ignoring origins.** An origin that answers a range request with 200 is now detected at open and reopened sequentially. Before, the load hung for more than 45 s.
- **Missing HEVC colour.** When the container states no colour, the demuxer now adopts the colour from the HEVC VUI. HDR10 in an MKV without a Colour element failed with -12927.
- **Seek during the end-of-file drain (software route).** A seek that arrives during the drain no longer ends the session. Every backward seek after a read-to-EOF had ended playback.
- **Seek axis (software route).** Seeks now use the source axis. A TS whose PTS starts at 23 000 s never presented a frame after a seek.

Open items, worst first:

- **Seek stutter on software AV1.** The clock restarts before decode has a cushion, so the display starves for 100-1000 ms after each seek (`jf-av1-*`). This needs a post-seek preroll gate.
- **Truncated or partial files.** On a file with a declared duration past the end of its data, a seek past the data never lands and stalls for 12 s (`ff-eac3-mkv`, `ff-vobsub-largeres`, `g-mkv-truncated`, `ff-lalaland-4k-hdr`). It should land at the data's end, or end the session.
- **Sequential MKV.** With the range quirk and no declared duration, a sequential MKV mis-plans and the startup seek to 0 fails it (`q-range-ignored-mkv`).
- **Origin without Content-Length.** A chunked origin with no length (`q-no-length`) fails demuxer reads on the software route.
- **Interlaced H.264 TS.** PAFF/MBAFF TS and MPEG-2 1080i on the software route freeze for 0.5-2.7 s while playing.
- **Bipbop black flash.** The remote bypass shows a black frame at every seek on Apple's bipbop fMP4. This needs a check that the black frame is not part of the content.
- **Smaller items:**
  - `ff-vc1-mkv` ends at 0.76 s of 7 s.
  - The TS PTS-wrap row's 90 % seek never lands.
  - After a 403 expiry, the 90 % seek never lands. It should surface an error.
  - RealVideo (`ff-mkv-size-change`) is unsupported by design.
