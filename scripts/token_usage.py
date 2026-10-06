#!/usr/bin/env python3
"""Exact token usage from Claude Code transcripts, summed per model.

Every API call Claude Code makes is logged in the session transcript with its
`usage`. A session's real usage is the sum over all calls, in the main
transcript and in the subagent transcripts next to it. (Before 0.23.0 the
plugin sent only the last call's usage, roughly 40x below the real figure.)

  token_usage.py snapshot <transcript.jsonl>
      Cumulative totals for one transcript, as a usageSnapshot JSON object
      ({} when there is nothing to report). Parses incrementally: byte
      offsets and per-call usage are cached under ~/.cache/devscope/usage/,
      so a Stop hook only reads what was appended since the last one.

  token_usage.py upload <projects-dir>
      /devscope:backfill-usage: snapshot every transcript under the Claude
      Code projects directory and POST them in batches to
      $DEVSCOPE_URL/api/sessions/usage/backfill. Reads DEVSCOPE_URL and
      DEVSCOPE_API_KEY from the environment so the key never appears in argv.

Only token counts and model ids leave the machine, never transcript content.
"""
import glob
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

CACHE_VERSION = 1
BATCH = 100  # well under the backend's 256 KB body limit


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "devscope", "usage")


def call_usage(entry, session_id):
    """(key, model, usage tuple) for an assistant entry with usage, else None."""
    if entry.get("type") != "assistant":
        return None
    # Resumed or forked transcripts could carry entries from another session.
    sid = entry.get("sessionId")
    if sid and session_id and sid != session_id:
        return None
    msg = entry.get("message") or {}
    u = msg.get("usage")
    model = msg.get("model")
    if not isinstance(u, dict) or not model or model == "<synthetic>":
        return None
    key = msg.get("id") or entry.get("requestId") or entry.get("uuid")
    if not key:
        return None
    write = int(u.get("cache_creation_input_tokens") or 0)
    breakdown = u.get("cache_creation") or {}
    write_1h = int(breakdown.get("ephemeral_1h_input_tokens") or 0)
    return key, model, [
        int(u.get("input_tokens") or 0),
        int(u.get("output_tokens") or 0),
        max(write - write_1h, 0),
        write_1h,
        int(u.get("cache_read_input_tokens") or 0),
    ]


def scan_file(path, state, session_id):
    """Read complete lines appended since state['offset'] into state['calls']."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if size < state.get("offset", 0):
        # Rewritten or truncated: start over.
        state["offset"] = 0
        state["calls"] = {}
    calls = state.setdefault("calls", {})
    with open(path, "rb") as f:
        f.seek(state.get("offset", 0))
        data = f.read()
    end = data.rfind(b"\n")
    if end < 0:
        return
    for raw in data[: end + 1].splitlines():
        if not raw.strip():
            continue
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        hit = call_usage(entry, session_id)
        if hit:
            key, model, usage = hit
            # One call is logged once per content block; the last line wins.
            calls[key] = [model] + usage
    state["offset"] = state.get("offset", 0) + end + 1


def transcript_files(transcript):
    base = transcript[: -len(".jsonl")] if transcript.endswith(".jsonl") else transcript
    return [transcript] + sorted(glob.glob(os.path.join(base, "subagents", "*.jsonl")))


def load_cache(path):
    try:
        with open(path) as f:
            c = json.load(f)
        if c.get("version") == CACHE_VERSION:
            return c
    except (OSError, ValueError):
        pass
    return {"version": CACHE_VERSION, "files": {}}


def save_cache(path, cache):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
        with os.fdopen(fd, "w") as f:
            json.dump(cache, f, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError:
        pass


def snapshot(transcript, use_cache=True):
    if not transcript or not os.path.isfile(transcript):
        return {}
    transcript_id = os.path.basename(transcript)
    if transcript_id.endswith(".jsonl"):
        transcript_id = transcript_id[: -len(".jsonl")]
    cache_path = os.path.join(cache_dir(), transcript_id + ".json")
    cache = load_cache(cache_path) if use_cache else {"version": CACHE_VERSION, "files": {}}

    by_model = {}
    seen = set()
    for path in transcript_files(transcript):
        state = cache["files"].setdefault(path, {})
        scan_file(path, state, transcript_id)
        for key, (model, *u) in state.get("calls", {}).items():
            if key in seen:  # old Claude Code logged sidechains in the main file too
                continue
            seen.add(key)
            m = by_model.setdefault(model, {"input": 0, "output": 0, "cacheWrite5m": 0,
                                            "cacheWrite1h": 0, "cacheRead": 0, "calls": 0})
            m["input"] += u[0]
            m["output"] += u[1]
            m["cacheWrite5m"] += u[2]
            m["cacheWrite1h"] += u[3]
            m["cacheRead"] += u[4]
            m["calls"] += 1
    if use_cache:
        save_cache(cache_path, cache)
    if not by_model:
        return {}
    return {"transcriptId": transcript_id, "byModel": by_model}


def post(url, key, items):
    req = urllib.request.Request(
        url.rstrip("/") + "/api/sessions/usage/backfill",
        data=json.dumps({"items": items}).encode(),
        headers={"Content-Type": "application/json", "x-requested-with": "devscope-cli",
                 **({"x-api-key": key} if key else {})},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def upload(projects_dir):
    url = os.environ.get("DEVSCOPE_URL", "http://localhost:6767")
    key = os.environ.get("DEVSCOPE_API_KEY", "")
    transcripts = sorted(glob.glob(os.path.join(projects_dir, "*", "*.jsonl")))
    items = [s for s in (snapshot(t, use_cache=False) for t in transcripts) if s]
    applied = skipped = 0
    try:
        for i in range(0, len(items), BATCH):
            res = post(url, key, items[i : i + BATCH])
            applied += int(res.get("applied", 0))
            skipped += int(res.get("skipped", 0))
    except urllib.error.HTTPError as e:
        print(json.dumps({"error": f"HTTP {e.code}", "transcripts": len(transcripts),
                          "applied": applied, "skipped": skipped}))
        return 1
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(json.dumps({"error": str(e), "transcripts": len(transcripts),
                          "applied": applied, "skipped": skipped}))
        return 1
    print(json.dumps({"transcripts": len(transcripts), "withUsage": len(items),
                      "applied": applied, "skipped": skipped}))
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "snapshot":
        try:
            json.dump(snapshot(argv[2]), sys.stdout, separators=(",", ":"))
        except Exception:  # a hook must never fail because of usage parsing
            sys.stdout.write("{}")
        return 0
    if len(argv) == 3 and argv[1] == "upload":
        return upload(argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
