#!/usr/bin/env python3
"""When background Bash commands finished, from the Claude Code transcript.

A Bash command run with `run_in_background` (or moved to the background after
its timeout, or by the user) reports PostToolUse as soon as it is backgrounded,
and no hook fires when it settles. Claude Code does log the settling: it
enqueues a <task-notification> for the model, and the transcript records that
as a `queue-operation` entry with `operation: "enqueue"` and a timestamp:

  <task-notification>
  <task-id>b5r0fuwka</task-id>
  <tool-use-id>toolu_016AWJ...</tool-use-id>
  <output-file>/tmp/claude-1000/.../tasks/b5r0fuwka.output</output-file>
  <status>completed</status>
  <summary>Background command "..." completed (exit code 0)</summary>
  </task-notification>

  bg_commands.py scan <transcript.jsonl>
      The commands that settled since the last scan, as a JSON array of
      {toolUseId, taskId, status, exitCode?, finishedAt} ([] when none).
      Reads incrementally: the byte offset of the last complete line is kept
      in ~/.cache/devscope/bg/<transcript>.offset.

Only ids, the status, the exit code and the time leave the machine: never the
command, its description (inside the summary) or its output path.
"""
import json
import os
import re
import sys
import tempfile

MAX_ITEMS = 200  # the backend accepts at most 200 per event

NOTIFICATION = re.compile(r"<task-notification>(.*?)</task-notification>", re.S)


def tag(body, name):
    m = re.search(r"<%s>(.*?)</%s>" % (name, name), body, re.S)
    return m.group(1).strip() if m else ""


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "devscope", "bg")


def offset_path(transcript):
    name = re.sub(r"[^A-Za-z0-9_-]", "", os.path.basename(transcript).rsplit(".jsonl", 1)[0])
    return os.path.join(cache_dir(), (name or "transcript") + ".offset")


def parse_entry(entry):
    """A settled background command from one transcript entry, else None."""
    if entry.get("type") != "queue-operation" or entry.get("operation") != "enqueue":
        return None
    content = entry.get("content")
    if not isinstance(content, str) or "<task-notification>" not in content:
        return None
    m = NOTIFICATION.search(content)
    if not m:
        return None
    body = m.group(1)
    summary = tag(body, "summary")
    # Agents and monitors send task notifications too; only shells count here.
    if not summary.startswith("Background command"):
        return None
    tool_use_id = tag(body, "tool-use-id")
    status = tag(body, "status")
    finished_at = entry.get("timestamp")
    if not tool_use_id or not status or not isinstance(finished_at, str):
        return None
    item = {
        "toolUseId": tool_use_id[:200],
        "taskId": tag(body, "task-id")[:100],
        "status": status[:20],
        "finishedAt": finished_at[:50],
    }
    code = re.search(r"exit code (-?\d+)", summary)
    if code:
        item["exitCode"] = int(code.group(1))
    return item


def scan(transcript):
    if not os.path.isfile(transcript):
        return []
    state = offset_path(transcript)
    try:
        with open(state) as f:
            offset = int(f.read().strip() or 0)
    except (OSError, ValueError):
        offset = 0
    size = os.path.getsize(transcript)
    if offset > size:  # rewritten transcript: start over
        offset = 0
    found, seen = [], set()
    with open(transcript, "rb") as f:
        f.seek(offset)
        for raw in f:
            if not raw.endswith(b"\n"):
                break  # half-written line: read it next time
            offset += len(raw)
            if b'"queue-operation"' not in raw:
                continue
            try:
                item = parse_entry(json.loads(raw))
            except (ValueError, AttributeError):
                continue
            if item and item["toolUseId"] not in seen and len(found) < MAX_ITEMS:
                seen.add(item["toolUseId"])
                found.append(item)
    os.makedirs(cache_dir(), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=cache_dir())
    with os.fdopen(fd, "w") as f:
        f.write(str(offset))
    os.replace(tmp, state)
    return found


def main(argv):
    if len(argv) != 3 or argv[1] != "scan":
        print(__doc__, file=sys.stderr)
        return 2
    try:
        print(json.dumps(scan(argv[2]), separators=(",", ":")))
    except Exception:  # never break a hook
        print("[]")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
