# Smoke tests

End-to-end check that every plugin hook script will produce a payload the
DevScope backend accepts.

## Layout

- `fixtures/<hook-name>.json` — recorded stdin payloads, one per hook script.
  The runner pipes each fixture into `scripts/<hook-name>.sh`, so the filename
  must match a script in `../../scripts/`.
- `run.sh` — driver. Waits for `$DEVSCOPE_URL/api/health`, replays every
  fixture, and asserts the backend returned 2xx for each event.

## Adding a fixture

1. Drop a JSON file at `fixtures/<hook-name>.json` that matches the stdin
   shape Claude Code sends to that hook.
2. Use the placeholder `__SMOKE_CWD__` for any field that should resolve to a
   real git working directory at runtime — `run.sh` substitutes it with a
   throwaway repo it creates per run.

## Running locally

```bash
# In one terminal: bring up backend + postgres from the devscope monorepo.
cd ../devscope
POSTGRES_PASSWORD=smoke BETTER_AUTH_SECRET=smoke-secret-32-bytes-long-okay \
  DEVSCOPE_ADMIN_PASSWORD=smoke DEVSCOPE_ADMIN_EMAIL=smoke@devscope.test \
  docker compose up -d --build postgres backend

# In another terminal: run the smoke driver against the running backend.
DEVSCOPE_URL=http://localhost:6767 ./tests/smoke/run.sh
```

CI runs the same driver against a freshly-built backend container — see
`.github/workflows/ci.yml`.
