# Retry queue integration test

End-to-end check that the on-disk retry buffer (DEV-23) survives backend
outages without losing events.

## What it covers

`run.sh` boots a tiny toggleable Python HTTP server (no external backend
required) and walks five phases:

1. **Backend down** → `send-event.sh` enqueues every event under
   `$DEVSCOPE_QUEUE_DIR`.
2. **Backend up** → `drain-queue.sh` replays the queue and the backend
   sees every event.
3. **Replay** → 3× the same logical event with the backend down, then up;
   plugin keeps re-POSTing until each entry gets a 2xx, then drops it.
4. **Mid-flight drop** → events sent during an outage are buffered, events
   sent before/after are delivered directly, and recovery drains the
   buffer.
5. **Cap enforcement** → with `DEVSCOPE_QUEUE_MAX=4` the queue never
   grows past 4 entries; oldest is pruned first.

## Running locally

```bash
bash tests/queue/run.sh
```

No backend / Docker / network setup needed. CI runs the same driver — see
`.github/workflows/ci.yml` (`queue-buffer` job).

## Notes

- Locking uses `mkdir` (atomic on POSIX) so the queue works the same on
  Linux and macOS without depending on `flock`.
- Backend idempotency is verified separately by the backend's own test
  suite. This driver only asserts the plugin re-POSTs until the backend
  returns 2xx.
