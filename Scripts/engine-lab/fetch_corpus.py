#!/usr/bin/env python3
"""Fetch and generate the engine-lab corpus described in corpus.json.

Media never lands in the repo or on a network share: everything goes under the corpus
root (default ~/Developer/openstream-build/engine-lab/corpus, override with
ENGINE_LAB_CORPUS). Downloads are range-limited so the whole corpus stays small:

  * a file up to --full-max bytes (default 150 MB) is downloaded whole;
  * a larger stream-tolerant container (ts/m2ts/mkv/mpg/webm, or force_range) is cut
    with an HTTP Range request at cap_bytes (a partial download, which is itself a case);
  * anything else (MP4/MOV) is remuxed with `ffmpeg -t <trim> -c copy` straight off the
    origin, which reads only what the first seconds need.

Generated entries run the exact command listed in corpus.json with {master} (the Sintel
mezzanine), {out}, {tmp}, {corpus} and {hdr10plus_json} substituted.

  python3 Scripts/engine-lab/fetch_corpus.py [--only id,id] [--category c] [--force] [--list]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
STREAMABLE = {".ts", ".m2ts", ".mts", ".m2t", ".mkv", ".mpg", ".mpeg", ".webm", ".vob", ".sup", ".avi"}
CAP_GB = 40


def corpus_root(manifest):
    return os.path.expanduser(os.environ.get("ENGINE_LAB_CORPUS", manifest["corpus_root"]))


def quote_url(url):
    p = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((p.scheme, p.netloc, urllib.parse.quote(urllib.parse.unquote(p.path)), p.query, p.fragment))


def head_size(url):
    req = urllib.request.Request(quote_url(url), method="HEAD", headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            n = r.headers.get("Content-Length")
            return int(n) if n else None
    except Exception:
        return None


def curl(url, out, max_bytes=None):
    cmd = ["curl", "-sSfL", "-A", UA, "--retry", "3", "--connect-timeout", "20", "-o", out]
    if max_bytes:
        cmd += ["-r", f"0-{max_bytes - 1}"]
    cmd.append(quote_url(url))
    return subprocess.run(cmd).returncode == 0


def du_bytes(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def hdr10plus_json(root):
    """A small, valid HDR10+ (ST 2094-40) metadata file for x265's dhdr10-info.

    x265 reads the per-frame JSON format hdr10plus_tool emits; one scene, values repeated
    per frame, enough for a decoder to see the SEI on every frame."""
    path = os.path.join(root, "generated-hdr10plus.json")
    frames = []
    for i in range(15 * 25):
        frames.append({
            "BezierCurveData": {"Anchors": [102, 205, 307, 410, 512, 614, 717, 819, 922], "KneePointX": 32, "KneePointY": 32},
            "LuminanceParameters": {"AverageRGB": 1200, "LuminanceDistributions": {
                "DistributionIndex": [1, 5, 10, 25, 50, 75, 90, 95, 99],
                "DistributionValues": [10, 30, 60, 300, 1000, 3000, 6000, 8000, 9800]}, "MaxScl": [9000, 9500, 8800]},
            "NumberOfWindows": 1, "TargetedSystemDisplayMaximumLuminance": 400,
        })
    doc = {"JSONInfo": {"HDR10plusProfile": "B", "Version": "1.0"},
           "SceneInfo": frames,
           "SceneInfoSummary": {"SceneFirstFrameIndex": [0], "SceneFrameNumbers": [len(frames)]},
           "ToolInfo": {"Tool": "engine-lab", "Version": "1"}}
    with open(path, "w") as f:
        json.dump(doc, f)
    return path


def fetch(entry, root, full_max, force):
    out = os.path.join(root, entry["file"])
    if os.path.exists(out) and os.path.getsize(out) > 0 and not force:
        return "cached"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".part"
    url = entry["url"]
    ext = os.path.splitext(out)[1].lower()
    if "trim" in entry:
        cmd = ["ffmpeg", "-y", "-v", "error", "-user_agent", UA]
        if entry.get("trim_start"):
            cmd += ["-ss", str(entry["trim_start"])]
        cmd += ["-i", quote_url(url), "-t", str(entry["trim"]), "-map", "0", "-c", "copy"]
        if ext in (".mp4", ".mov"):
            cmd += ["-movflags", "+faststart", "-f", "mp4" if ext == ".mp4" else "mov"]
        else:
            cmd += ["-f", "matroska"]
        cmd.append(tmp)
        ok = subprocess.run(cmd).returncode == 0
        how = f"trim {entry['trim']}s"
    else:
        size = head_size(url)
        cap = entry.get("cap_bytes", 80_000_000)
        if entry.get("force_range") or (size and size > full_max and ext in STREAMABLE):
            ok = curl(url, tmp, cap)
            how = f"range 0-{cap // 1_000_000}MB of {size // 1_000_000 if size else '?'}MB"
        elif size and size > full_max:
            print(f"  SKIP {entry['id']}: {size // 1_000_000} MB and not range-safe; add trim")
            return "skipped"
        else:
            ok = curl(url, tmp)
            how = "full"
    if ok and os.path.exists(tmp):
        os.replace(tmp, out)
        return how
    if os.path.exists(tmp):
        os.remove(tmp)
    return "FAILED"


def generate(entry, root, master, force):
    out = os.path.join(root, entry["file"])
    if os.path.exists(out) and os.path.getsize(out) > 0 and not force:
        return "cached"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = os.path.join(root, ".tmp-" + entry["id"])
    subst = {"{master}": master, "{out}": out, "{tmp}": tmp, "{corpus}": root,
             "{hdr10plus_json}": hdr10plus_json(root) if any("{hdr10plus_json}" in c for c in entry["cmd"]) else ""}
    cmd = []
    for part in entry["cmd"]:
        for k, v in subst.items():
            part = part.replace(k, v)
        cmd.append(part)
    r = subprocess.run(cmd)
    # mkvmerge exits 1 on warnings with a usable file
    if (r.returncode == 0 or (cmd[0] == "mkvmerge" and r.returncode == 1)) and os.path.exists(out) and os.path.getsize(out) > 0:
        return "generated"
    if os.path.exists(out):
        os.remove(out)
    return "FAILED"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(HERE, "corpus.json"))
    ap.add_argument("--only")
    ap.add_argument("--category")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--full-max", type=int, default=150_000_000)
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    manifest = json.load(open(a.manifest))
    root = corpus_root(manifest)
    os.makedirs(root, exist_ok=True)
    entries = manifest["entries"]
    if a.list:
        for e in entries:
            print(f"{e['id']:32} {e['category']:14} {e['kind']:9} {e.get('notes', '')}")
        return
    only = set(a.only.split(",")) if a.only else None
    by_id = {e["id"]: e for e in entries}
    master_entry = by_id[manifest["master"]]
    master = os.path.join(root, master_entry["file"])
    order = [e for e in entries if e["kind"] == "download"] + [e for e in entries if e["kind"] == "generate"]
    status = {}
    for e in order:
        if only and e["id"] not in only and not (e["id"] == manifest["master"] and any(
                by_id[i]["kind"] == "generate" for i in only if i in by_id)):
            continue
        if a.category and e["category"] != a.category and e["id"] != manifest["master"]:
            continue
        if du_bytes(root) > CAP_GB * 1e9:
            print(f"corpus over {CAP_GB} GB, stopping")
            break
        if e["kind"] == "download":
            s = fetch(e, root, a.full_max, a.force)
        else:
            if not os.path.exists(master):
                s = "FAILED (no master)"
            elif any(not os.path.exists(os.path.join(root, by_id[r]["file"])) for r in e.get("requires", [])):
                s = "FAILED (missing requirement)"
            else:
                s = generate(e, root, master, a.force)
        status[e["id"]] = s
        print(f"  {e['id']:32} {s}", flush=True)
    print(f"corpus: {du_bytes(root) / 1e9:.2f} GB at {root}")
    failed = [k for k, v in status.items() if v.startswith("FAILED")]
    if failed:
        print("failed:", ", ".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    main()
