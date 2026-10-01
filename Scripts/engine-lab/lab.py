#!/usr/bin/env python3
"""Engine lab runner: corpus -> aetherctl lab -> ffprobe oracle -> scoreboard.

  python3 Scripts/engine-lab/lab.py run [--label L] [--only id,id] [--category c] [--seconds 6]
                                        [--aetherctl PATH] [--baseline RUN_DIR]
  python3 Scripts/engine-lab/lab.py compare RUN_A RUN_B      # before/after table
  python3 Scripts/engine-lab/lab.py rescore RUN_DIR          # re-apply thresholds, rewrite scoreboard

One aetherctl process per source (a crash or wedge costs one row). Runs are written to
~/Developer/openstream-build/engine-lab/runs/<stamp>-<label>/ (ENGINE_LAB_HOME overrides):
results/<id>.json per source, scoreboard.md, summary.json. Each run is compared with the
previous one (or --baseline) and the delta is appended to the scoreboard.

Thresholds live in THRESHOLDS below and are documented in docs/engine-lab.md.
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import quirk_server  # noqa: E402

LAB_HOME = os.path.expanduser(os.environ.get("ENGINE_LAB_HOME", "~/Developer/openstream-build/engine-lab"))
DEFAULT_AETHERCTL = os.path.expanduser("~/Developer/openstream-build/aether-fork-spm/debug/aetherctl")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

THRESHOLDS = {
    "open_s_local": 5.0,          # load() return, local file
    "open_s_remote": 12.0,        # remote / quirk origin
    "ttff_s_local": 2.5,          # load call -> first presented frame
    "ttff_s_remote": 6.0,
    "slow_first_byte_extra_s": 8.0,   # allowance on top for the slow-first-byte quirk
    "clean_fail_s": 15.0,         # a source that must fail has to fail within this
    "play_clock_ratio": 0.8,      # clock advance over the play window / window length
    "dropped_ratio": 0.02,        # missing frames / presented frames in the play window
    "play_freezes": 0,            # wall-clock holes > max(250 ms, 4 frames) while playing
    "seek_latency_ms_local": 1500,
    "seek_latency_ms_remote": 3000,
    "post_seek_hold_ms": 250,     # landing frame held on screen longer than this = stutter
    "post_seek_freezes": 0,
    "post_seek_pts_gaps": 0,
    "landing_error_s": 2.0,       # |clock at landing - target|
    "video_vs_clock_ms": 100,
    "engine_av_gap_ms": 100,
    "clock_rate_error": 0.03,
    "memory_mb_hd": 700,
    "memory_mb_uhd": 1400,
}

METRICS = ["crash", "open", "oracle", "ttff", "playback", "frames", "seek_latency", "seek_continuity", "av_drift", "memory"]
WEIGHT = {"crash": 10, "open": 10, "playback": 6, "seek_latency": 4, "seek_continuity": 4, "ttff": 3,
          "frames": 2, "av_drift": 2, "memory": 2, "oracle": 1}


def load_manifest():
    m = json.load(open(os.path.join(HERE, "corpus.json")))
    m["root"] = os.path.expanduser(os.environ.get("ENGINE_LAB_CORPUS", m["corpus_root"]))
    return m


def git_rev():
    try:
        rev = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", REPO, "status", "--porcelain", "--", "Sources"], capture_output=True, text=True).stdout.strip()
        return rev + ("+dirty" if dirty else "")
    except Exception:
        return "?"


# ---------------------------------------------------------------- oracle

def ffprobe(target, timeout=40):
    cmd = ["ffprobe", "-v", "error", "-of", "json", "-show_format", "-show_streams"]
    if target.startswith("http"):
        cmd += ["-user_agent", UA, "-rw_timeout", "20000000"]
    cmd.append(target)
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout", "seconds": round(time.time() - t0, 2)}
    out = {"seconds": round(time.time() - t0, 2)}
    if r.returncode != 0:
        out.update(ok=False, error=(r.stderr.strip().splitlines() or ["?"])[-1][:200])
        return out
    try:
        j = json.loads(r.stdout)
    except ValueError:
        out.update(ok=False, error="unparseable")
        return out
    streams = j.get("streams", [])
    if not streams:
        out.update(ok=False, error="no streams")
        return out
    video = [s for s in streams if s.get("codec_type") == "video" and not s.get("disposition", {}).get("attached_pic")]
    dv = None
    for s in video:
        for sd in s.get("side_data_list", []) or []:
            if "dv_profile" in sd:
                dv = sd["dv_profile"]
    out.update(
        ok=True,
        format=j.get("format", {}).get("format_name"),
        duration=float(j.get("format", {}).get("duration") or 0) or None,
        video=[{"codec": s.get("codec_name"), "w": s.get("width"), "h": s.get("height"),
                "pix_fmt": s.get("pix_fmt"), "transfer": s.get("color_transfer"),
                "field_order": s.get("field_order")} for s in video],
        audio=[{"codec": s.get("codec_name"), "channels": s.get("channels"), "profile": s.get("profile")}
               for s in streams if s.get("codec_type") == "audio"],
        subtitles=[{"codec": s.get("codec_name")} for s in streams if s.get("codec_type") == "subtitle"],
        dvProfile=dv,
    )
    return out


def oracle_compare(engine, oracle):
    """Return (status, notes). FAIL only when the two disagree on whether the source opens
    or on what the first video stream is; track-count differences are notes (the engine
    hides tracks it cannot deliver on purpose)."""
    eopen = bool(engine.get("open", {}).get("ok"))
    if not oracle.get("ok"):
        return ("PASS" if not eopen else "NOTE", [f"ffprobe cannot open ({oracle.get('error')}), engine {'opens' if eopen else 'fails too'}"])
    if not eopen:
        return ("FAIL", ["ffprobe opens it, engine does not"])
    notes = []
    status = "PASS"
    probe = engine.get("probe", {})
    if oracle["video"]:
        ov = oracle["video"][0]["codec"]
        ev = (probe.get("videoCodec") or "")
        if ev and ov and ev != ov:
            notes.append(f"video codec {ev} vs ffprobe {ov}")
            status = "FAIL"
        if not ev and engine.get("route", {}).get("videoRoute") == "audio":
            notes.append("ffprobe sees video, engine routed audio-only")
            status = "FAIL"
    ea = len(probe.get("audio", []))
    if ea != len(oracle["audio"]):
        notes.append(f"audio tracks {ea} vs ffprobe {len(oracle['audio'])}")
    es = len([s for s in probe.get("subtitles", []) if not s.get("external")])
    if es != len(oracle["subtitles"]):
        notes.append(f"subtitle tracks {es} vs ffprobe {len(oracle['subtitles'])}")
    if oracle.get("dvProfile") is not None and probe.get("dvProfile") != oracle["dvProfile"]:
        notes.append(f"DV profile {probe.get('dvProfile')} vs ffprobe {oracle['dvProfile']}")
        status = "FAIL"
    od, ed = oracle.get("duration"), probe.get("duration")
    if od and ed and abs(od - ed) > max(2.0, 0.05 * od):
        notes.append(f"duration {ed:.1f}s vs ffprobe {od:.1f}s")
    return status, notes


# ---------------------------------------------------------------- scoring

def score(entry, r):
    """Per-metric PASS / FAIL / N/A for one result. Returns (scores, reasons)."""
    T = THRESHOLDS
    s, why = {}, {}
    remote = entry["kind"] in ("remote", "quirk")
    expect = entry.get("expect", "play")
    if r.get("harness_error"):
        s["crash"] = "FAIL"
        why["crash"] = r["harness_error"]
        for m in METRICS[1:]:
            s[m] = "N/A"
        if "oracle" in r:
            s["oracle"] = "FAIL" if r["oracle"].get("ok") else "N/A"
        return s, why
    s["crash"] = "PASS"
    op = r.get("open", {})
    opened = bool(op.get("ok"))
    open_s = op.get("seconds", 99)
    budget = T["open_s_remote"] if remote else T["open_s_local"]
    if entry.get("quirk") == "slow-first-byte":
        budget += T["slow_first_byte_extra_s"]
    if expect == "clean-fail":
        ok = (not opened) and open_s <= T["clean_fail_s"] and op.get("errorKind") != "timeout"
        s["open"] = "PASS" if ok else "FAIL"
        if not ok:
            why["open"] = "opened a source that must fail" if opened else f"failed slowly ({open_s}s, {op.get('errorKind')})"
        for m in ("ttff", "playback", "frames", "seek_latency", "seek_continuity", "av_drift"):
            s[m] = "N/A"
    else:
        if not opened:
            if expect == "no-wedge" and op.get("errorKind") != "timeout":
                s["open"] = "PASS"
            else:
                s["open"] = "FAIL"
                why["open"] = f"{op.get('errorKind')}: {op.get('message', '')[:120]}"
            for m in ("ttff", "playback", "frames", "seek_latency", "seek_continuity", "av_drift"):
                s[m] = "N/A"
        else:
            s["open"] = "PASS" if open_s <= budget else "FAIL"
            if s["open"] == "FAIL":
                why["open"] = f"open took {open_s}s (> {budget}s)"
    if opened and expect != "clean-fail":
        video = r.get("route", {}).get("videoRoute") not in ("audio", "none", None)
        ff = r.get("firstFrame", {})
        tbudget = (T["ttff_s_remote"] if remote else T["ttff_s_local"]) + (
            T["slow_first_byte_extra_s"] if entry.get("quirk") == "slow-first-byte" else 0)
        if not video:
            s["ttff"] = "N/A"
        elif not ff.get("ok"):
            s["ttff"] = "FAIL"
            why["ttff"] = "no frame presented"
        else:
            s["ttff"] = "PASS" if ff["seconds"] <= tbudget else "FAIL"
            if s["ttff"] == "FAIL":
                why["ttff"] = f"first frame at {ff['seconds']}s (> {tbudget}s)"
        pl = r.get("play", {})
        win = pl.get("seconds") or 1
        adv = pl.get("clockAdvance", 0)
        errs = r.get("stateErrors") or []
        live = r.get("probe", {}).get("isLive")
        if errs:
            s["playback"] = "FAIL"
            why["playback"] = "state error: " + errs[0][:120]
        elif pl.get("endedAtClock") is not None and (r.get("oracle", {}).get("duration") or r.get("probe", {}).get("duration") or 0) > pl["endedAtClock"] + 2:
            s["playback"] = "FAIL"
            dur = r.get("oracle", {}).get("duration") or r.get("probe", {}).get("duration")
            why["playback"] = f"ended at {pl['endedAtClock']}s of a {dur:.1f}s source"
        elif adv < T["play_clock_ratio"] * (win - 1.0):
            s["playback"] = "FAIL"
            why["playback"] = f"clock advanced {adv}s in {win}s"
        else:
            s["playback"] = "PASS"
        c = pl.get("continuity", {})
        if not video or not c.get("frames"):
            s["frames"] = "N/A" if not video else "FAIL"
            if video:
                why["frames"] = "no frames in play window"
        else:
            ratio = c.get("missingFrames", 0) / max(1, c["frames"])
            st = pl.get("displayStarvation", {})
            ok = ratio <= T["dropped_ratio"] and c.get("freezes", 0) <= T["play_freezes"] and not st.get("events")
            s["frames"] = "PASS" if ok else "FAIL"
            if not ok:
                why["frames"] = (f"missing {c.get('missingFrames')}/{c['frames']}, freezes {c.get('freezes')}, "
                                 f"max gap {c.get('maxFrameGapMs')}ms" + (f", display starved {st.get('events')}x" if st.get("events") else ""))
        seeks = r.get("seeks") or []
        if not seeks:
            s["seek_latency"] = s["seek_continuity"] = "N/A"
            dur = max(r.get("probe", {}).get("duration") or 0, (r.get("oracle") or {}).get("duration") or 0)
            if not live and r.get("seeksSkipped") not in ("live", "disabled") and dur > 10:
                s["seek_latency"] = "FAIL"
                why["seek_latency"] = f"no seeks ran ({r.get('seeksSkipped')})"
        else:
            sb = T["seek_latency_ms_remote"] if remote else T["seek_latency_ms_local"]
            bad = []
            for k in seeks:
                if not k.get("landed"):
                    bad.append(f"{int(k['fraction'] * 100)}%: never landed" + (f" ({k.get('error')[:60]})" if k.get("error") else ""))
                elif k.get("frameLatencyMs", 1e9) > sb:
                    bad.append(f"{int(k['fraction'] * 100)}%: {k['frameLatencyMs']:.0f}ms")
                elif abs(k.get("landingErrorS", 0)) > T["landing_error_s"]:
                    bad.append(f"{int(k['fraction'] * 100)}%: landed {k.get('landingErrorS')}s off")
            s["seek_latency"] = "FAIL" if bad else "PASS"
            if bad:
                why["seek_latency"] = "; ".join(bad)
            cbad = []
            for k in seeks:
                cc = k.get("continuity")
                if not cc or not video:
                    continue
                pct = f"{int(k['fraction'] * 100)}%"
                if cc.get("freezes", 0) > T["post_seek_freezes"]:
                    cbad.append(f"{pct}: {cc['freezes']} freeze(s), max gap {cc.get('maxFrameGapMs')}ms")
                elif cc.get("firstFrameHoldMs", 0) > T["post_seek_hold_ms"]:
                    cbad.append(f"{pct}: landing frame held {cc['firstFrameHoldMs']:.0f}ms")
                if cc.get("ptsGaps", 0) > T["post_seek_pts_gaps"]:
                    cbad.append(f"{pct}: {cc['ptsGaps']} pts gap(s)")
                if cc.get("blackFlash"):
                    cbad.append(f"{pct}: black flash")
                if cc.get("backwardsPts"):
                    cbad.append(f"{pct}: {cc['backwardsPts']} backwards pts")
                if (k.get("displayStarvation") or {}).get("events"):
                    cbad.append(f"{pct}: display starved {k['displayStarvation']['events']}x")
            if not video:
                s["seek_continuity"] = "N/A"
            else:
                s["seek_continuity"] = "FAIL" if cbad else "PASS"
                if cbad:
                    why["seek_continuity"] = "; ".join(cbad)
        d = pl.get("drift", {})
        bad = []
        if d.get("videoVsClockMs") is not None and abs(d["videoVsClockMs"]) > T["video_vs_clock_ms"]:
            bad.append(f"video vs clock {d['videoVsClockMs']}ms")
        if d.get("engineAVGapMaxMs") is not None and d["engineAVGapMaxMs"] > T["engine_av_gap_ms"]:
            bad.append(f"engine A/V gap {d['engineAVGapMaxMs']}ms")
        if d.get("clockRate") is not None and abs(d["clockRate"] - 1) > T["clock_rate_error"] and s.get("playback") == "PASS":
            bad.append(f"clock rate {d['clockRate']}")
        s["av_drift"] = ("FAIL" if bad else "PASS") if d else "N/A"
        if bad:
            why["av_drift"] = ", ".join(bad)
    mem = r.get("memory", {}).get("peakMB")
    h = r.get("probe", {}).get("height") or 0
    mbudget = T["memory_mb_uhd"] if h > 1100 else T["memory_mb_hd"]
    if mem is None:
        s["memory"] = "N/A"
    else:
        s["memory"] = "PASS" if mem <= mbudget else "FAIL"
        if s["memory"] == "FAIL":
            why["memory"] = f"peak {mem:.0f}MB (> {mbudget})"
    if "oracle" in r:
        st, notes = oracle_compare(r, r["oracle"])
        s["oracle"] = "PASS" if st in ("PASS", "NOTE") else "FAIL"
        if notes:
            why["oracle"] = "; ".join(notes)
    for m in METRICS:
        s.setdefault(m, "N/A")
    return s, why


# ---------------------------------------------------------------- run

def target_for(entry, m, qport, run_id, who):
    if entry["kind"] == "remote":
        return entry["url"]
    if entry["kind"] == "local":
        return os.path.join(REPO, entry["path"])
    if entry["kind"] == "quirk":
        tgt = next(e for e in m["entries"] if e["id"] == entry["target"])
        session = f"{run_id}-{entry['id']}-{who}"
        return f"http://127.0.0.1:{qport}/q/{entry['quirk']}/{session}/" + urllib.parse.quote(tgt["file"])
    return os.path.join(m["root"], entry["file"])


def run_one(entry, m, aetherctl, seconds, qport, run_id, rdir):
    target = target_for(entry, m, qport, run_id, "engine")
    if entry["kind"] in ("download", "generate") and not os.path.exists(target):
        return None
    out = os.path.join(rdir, "results", entry["id"] + ".json")
    raw = os.path.join(rdir, "raw", entry["id"] + ".json")
    log = os.path.join(rdir, "logs", entry["id"] + ".log")
    cmd = [aetherctl, "lab", "--seconds", str(seconds), "--out", raw] + entry.get("lab_args", []) + [target]
    t0 = time.time()
    r = {}
    with open(log, "w") as lf:
        try:
            p = subprocess.run(cmd, stdout=lf, stderr=subprocess.STDOUT, timeout=180)
            code = p.returncode
        except subprocess.TimeoutExpired:
            code = "timeout"
    if os.path.exists(raw):
        r = json.load(open(raw))
    else:
        r["harness_error"] = f"aetherctl exit {code} without a result" + (" (crash)" if isinstance(code, int) and code < 0 else "")
    r["wallSeconds"] = round(time.time() - t0, 2)
    oracle_target = target_for(entry, m, qport, run_id, "oracle")
    r["oracle"] = ffprobe(oracle_target)
    r["id"], r["category"], r["kind"] = entry["id"], entry["category"], entry["kind"]
    if entry.get("quirk"):
        r["quirk"], r["expect"] = entry["quirk"], entry.get("expect")
    r["scores"], r["reasons"] = score(entry, r)
    json.dump(r, open(out, "w"), indent=1, sort_keys=True)
    return r


def summarize(results):
    rates = {}
    for mname in METRICS:
        vals = [r["scores"][mname] for r in results if r["scores"].get(mname) in ("PASS", "FAIL")]
        rates[mname] = (sum(v == "PASS" for v in vals), len(vals))
    return rates


def severity(r):
    return sum(WEIGHT[m] for m in METRICS if r["scores"].get(m) == "FAIL")


def fmt(v, unit="", nd=2):
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:.{nd}f}{unit}"
    return f"{v}{unit}"


def key_numbers(r):
    op = r.get("open", {})
    ff = r.get("firstFrame", {})
    seeks = r.get("seeks") or []
    lat = [k["frameLatencyMs"] for k in seeks if k.get("frameLatencyMs") is not None]
    hold = [k.get("continuity", {}).get("firstFrameHoldMs") for k in seeks if k.get("continuity", {}).get("firstFrameHoldMs") is not None]
    return {
        "open_s": op.get("seconds"),
        "ttff_s": ff.get("seconds"),
        "seek_max_ms": max(lat) if lat else None,
        "seek_hold_max_ms": max(hold) if hold else None,
        "mem_mb": r.get("memory", {}).get("peakMB"),
        "route": r.get("route", {}).get("videoRoute"),
    }


def write_scoreboard(rdir, results, meta, baseline=None):
    rates = summarize(results)
    lines = [f"# Engine lab scoreboard: {meta['label']}", "",
             f"- run `{os.path.basename(rdir)}`, engine `{meta['rev']}`, {meta['date']}",
             f"- {len(results)} sources ({meta['skipped']} not present on disk), play window {meta['seconds']} s, 3 seeks (50/90/10 %)",
             "", "## Pass rate per metric", "", "| metric | pass | total | rate |", "|---|---:|---:|---:|"]
    for mname in METRICS:
        p, n = rates[mname]
        lines.append(f"| {mname} | {p} | {n} | {(100 * p / n if n else 0):.0f}% |")
    worst = sorted([r for r in results if severity(r) > 0], key=lambda r: (-severity(r), r["id"]))
    lines += ["", f"## Worst offenders ({len(worst)} sources with a failure)", "",
              "| # | source | category | route | failing | why |", "|---:|---|---|---|---|---|"]
    for i, r in enumerate(worst, 1):
        fails = [m for m in METRICS if r["scores"].get(m) == "FAIL"]
        why = " / ".join(f"**{m}**: {r['reasons'].get(m, '')}" for m in fails)
        lines.append(f"| {i} | `{r['id']}` | {r['category']} | {key_numbers(r)['route'] or '-'} | {', '.join(fails)} | {why.replace('|', '/')} |")
    lines += ["", "## All sources", "",
              "| source | cat | route | open s | ttff s | seek max ms | hold max ms | mem MB | " + " | ".join(METRICS) + " |",
              "|---|---|---|---:|---:|---:|---:|---:|" + "|".join([":-:"] * len(METRICS)) + "|"]
    mark = {"PASS": "ok", "FAIL": "**X**", "N/A": "."}
    for r in sorted(results, key=lambda r: (r["category"], r["id"])):
        k = key_numbers(r)
        lines.append(f"| `{r['id']}` | {r['category']} | {k['route'] or '-'} | {fmt(k['open_s'])} | {fmt(k['ttff_s'])} | "
                     f"{fmt(k['seek_max_ms'], nd=0)} | {fmt(k['seek_hold_max_ms'], nd=0)} | {fmt(k['mem_mb'], nd=0)} | "
                     + " | ".join(mark.get(r["scores"].get(m), "?") for m in METRICS) + " |")
    notes = [(r["id"], r["reasons"]["oracle"]) for r in results if r["reasons"].get("oracle") and r["scores"].get("oracle") == "PASS"]
    if notes:
        lines += ["", "## Oracle notes (ffprobe disagreements that are not failures)", ""]
        lines += [f"- `{i}`: {n}" for i, n in notes]
    if baseline:
        lines += ["", delta_markdown(baseline, results, meta.get("baseline_name", "previous"))]
    open(os.path.join(rdir, "scoreboard.md"), "w").write("\n".join(lines) + "\n")
    json.dump({"meta": meta, "rates": rates,
               "rows": {r["id"]: {"scores": r["scores"], "numbers": key_numbers(r)} for r in results}},
              open(os.path.join(rdir, "summary.json"), "w"), indent=1, sort_keys=True)


def load_run(rdir):
    res = []
    d = os.path.join(rdir, "results")
    for f in sorted(os.listdir(d)):
        if f.endswith(".json"):
            res.append(json.load(open(os.path.join(d, f))))
    return res


def delta_markdown(before, after, name):
    b = {r["id"]: r for r in before}
    a = {r["id"]: r for r in after}
    rb, ra = summarize(before), summarize(after)
    lines = [f"## Delta vs {name}", "", "| metric | before | after |", "|---|---:|---:|"]
    for mname in METRICS:
        lines.append(f"| {mname} | {rb[mname][0]}/{rb[mname][1]} | {ra[mname][0]}/{ra[mname][1]} |")
    fixed, broke = [], []
    for i in sorted(set(a) & set(b)):
        for mname in METRICS:
            x, y = b[i]["scores"].get(mname), a[i]["scores"].get(mname)
            if x == "FAIL" and y == "PASS":
                fixed.append(f"`{i}` {mname}")
            elif x == "PASS" and y == "FAIL":
                broke.append(f"`{i}` {mname}: {a[i]['reasons'].get(mname, '')}")
    lines += ["", f"Fixed ({len(fixed)}): " + (", ".join(fixed) or "none"), "",
              f"Regressed ({len(broke)}): " + ("; ".join(broke) or "none")]
    rows = []
    for i in sorted(set(a) & set(b)):
        kb, ka = key_numbers(b[i]), key_numbers(a[i])
        for key in ("ttff_s", "seek_max_ms", "seek_hold_max_ms"):
            x, y = kb[key], ka[key]
            if x is None or y is None:
                continue
            scale = 1 if key == "ttff_s" else 1000
            if abs(y - x) * (1 if key == "ttff_s" else 0.001) >= 0.25 and abs(y - x) / max(abs(x), 1e-6) > 0.2:
                rows.append(f"| `{i}` | {key} | {fmt(x)} | {fmt(y)} |")
    if rows:
        lines += ["", "Moved by more than 20 % (and 250 ms):", "", "| source | number | before | after |", "|---|---|---:|---:|"] + rows
    return "\n".join(lines)


def previous_run(current):
    runs = sorted(d for d in os.listdir(os.path.join(LAB_HOME, "runs")) if os.path.isdir(os.path.join(LAB_HOME, "runs", d)))
    runs = [d for d in runs if os.path.join(LAB_HOME, "runs", d) != current
            and os.path.exists(os.path.join(LAB_HOME, "runs", d, "summary.json"))]
    return os.path.join(LAB_HOME, "runs", runs[-1]) if runs else None


def cmd_run(a):
    m = load_manifest()
    aetherctl = a.aetherctl or DEFAULT_AETHERCTL
    if not os.path.exists(aetherctl):
        sys.exit(f"no aetherctl at {aetherctl}: swift build --product aetherctl first")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    run_id = f"{stamp}-{a.label}"
    rdir = os.path.join(LAB_HOME, "runs", run_id)
    for sub in ("results", "raw", "logs"):
        os.makedirs(os.path.join(rdir, sub), exist_ok=True)
    srv, _ = quirk_server.start(m["root"], 0)
    qport = srv.server_address[1]
    only = set(a.only.split(",")) if a.only else None
    entries = [e for e in m["entries"] if e["kind"] in ("download", "generate", "remote", "quirk", "local")
               and not e.get("aux") and (not only or e["id"] in only) and (not a.category or e["category"] == a.category)]
    results, skipped = [], 0
    for i, e in enumerate(entries, 1):
        t0 = time.time()
        r = run_one(e, m, aetherctl, a.seconds, qport, run_id, rdir)
        if r is None:
            skipped += 1
            print(f"[{i}/{len(entries)}] {e['id']:30} (not on disk, skipped)", flush=True)
            continue
        results.append(r)
        fails = [k for k in METRICS if r["scores"].get(k) == "FAIL"]
        print(f"[{i}/{len(entries)}] {e['id']:30} {r.get('route', {}).get('videoRoute', '-'):12} "
              f"{'OK' if not fails else 'FAIL ' + ','.join(fails)} ({time.time() - t0:.0f}s)", flush=True)
    srv.shutdown()
    baseline_dir = a.baseline or previous_run(rdir)
    baseline = load_run(baseline_dir) if baseline_dir else None
    if baseline and only:
        baseline = [r for r in baseline if r["id"] in only]
    meta = {"label": a.label, "rev": git_rev(), "date": datetime.datetime.now().isoformat(timespec="seconds"),
            "seconds": a.seconds, "skipped": skipped, "thresholds": THRESHOLDS,
            "baseline_name": os.path.basename(baseline_dir) if baseline_dir else None}
    write_scoreboard(rdir, results, meta, baseline)
    latest = os.path.join(LAB_HOME, "runs", "latest")
    if os.path.islink(latest) or os.path.exists(latest):
        os.remove(latest)
    os.symlink(rdir, latest)
    print(f"\nscoreboard: {os.path.join(rdir, 'scoreboard.md')}")
    for mname, (p, n) in summarize(results).items():
        print(f"  {mname:16} {p}/{n}")


def cmd_rescore(a):
    m = load_manifest()
    by_id = {e["id"]: e for e in m["entries"]}
    results = load_run(a.run)
    for r in results:
        r["scores"], r["reasons"] = score(by_id[r["id"]], r)
        json.dump(r, open(os.path.join(a.run, "results", r["id"] + ".json"), "w"), indent=1, sort_keys=True)
    meta = json.load(open(os.path.join(a.run, "summary.json")))["meta"]
    meta["thresholds"] = THRESHOLDS
    base = a.baseline
    write_scoreboard(a.run, results, meta, load_run(base) if base else None)
    print(os.path.join(a.run, "scoreboard.md"))


def cmd_compare(a):
    before, after = load_run(a.before), load_run(a.after)
    ids = None
    if a.only:
        ids = set(a.only.split(","))
    if ids:
        before = [r for r in before if r["id"] in ids]
        after = [r for r in after if r["id"] in ids]
    print(delta_markdown(before, after, os.path.basename(a.before.rstrip("/"))))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--label", default="run")
    r.add_argument("--only")
    r.add_argument("--category")
    r.add_argument("--seconds", type=float, default=6)
    r.add_argument("--aetherctl")
    r.add_argument("--baseline")
    c = sub.add_parser("compare")
    c.add_argument("before")
    c.add_argument("after")
    c.add_argument("--only")
    s = sub.add_parser("rescore")
    s.add_argument("run")
    s.add_argument("--baseline")
    a = ap.parse_args()
    {"run": cmd_run, "compare": cmd_compare, "rescore": cmd_rescore}[a.cmd](a)


if __name__ == "__main__":
    main()
