# DevScope Live: in-session mod

A second plugin in this repo, `devscope-live`, built on Claude Code's function
hooks ("mods", early access, verified against 2.1.291). It brings DevScope's
cross-session knowledge into the live session, with the developer choosing
what happens, and collects the outcome signals that knowledge depends on.
The Bash plugin (`devscope`) keeps shipping events; the mod only adds.

## Features

| # | Feature | Trigger | What the developer sees |
|---|---|---|---|
| 2 | Team prompts | after a main-loop turn, and at session start | Ghost text in the empty prompt box (Tab to take): the next prompt that worked in similar sessions of the developer and of teammates who share their sessions |
| 3 | Team skills | a typed prompt matches an active team skill's trigger phrase | "Team skill X covers this. Use it?" dialog; *Use it* attaches the skill to that prompt as context |
| 6 | Stuck band | a tool call fails and the backend tripped a friction rule for the session | Band above the prompt: what keeps failing, with *Step back* (interrupt and ask Claude to reassess), *Stop* and *Keep going* |
| 8 | Outcome labels | implicit: the next prompt reads as praise or complaint; explicit: a long turn ends | Implicit labels are silent. Explicit: a band "Did that work?" with 👍 / partly / 👎, at most once per 30 min |
| 9 | Session ↔ commit link | a Bash `git commit` / `gh pr create` succeeds; session start | Nothing by default. Commits and PRs are recorded against the session; PR state is resolved locally with `gh`. Optional `DevScope-Session:` trailer on Claude's commits and PRs |

## Rules

- The developer chooses: nothing is attached to the model's context without a
  click (team skills) or an explicit action (step back).
- Fail open: any backend or `gh` failure leaves the session exactly as it was.
  Every network call has a short timeout.
- Privacy: `DEVSCOPE_PRIVACY=private` turns off everything that sends content
  or repository metadata (2, 8, 9). 3 and 6 send nothing but the session id.
- Ethics (devscope-cloud CLAUDE.md): suggestions come only from the caller's
  own sessions and teammates who opted in to sharing, never carry developer
  identity, and nothing ranks or compares people. Labels and VCS links are
  self-only.
- Each feature has a `userConfig` toggle. The commit trailer is off by default
  because it writes into git history.

## Configuration

The mod reads the same settings as the Bash plugin: `DEVSCOPE_URL`,
`DEVSCOPE_API_KEY`, `DEVSCOPE_PRIVACY` from the environment, else from
`${XDG_CONFIG_HOME:-~/.config}/devscope/config`.

## Backend contract (`/api/live`, devscope-cloud)

All routes accept the API key (`x-api-key`) or a session cookie, are
org-scoped, and treat `session_id` as Claude Code's current session id. The
backend resolves it to the DevScope session (`sessions.id`, or the session
whose `session.start` event carries it as `claudeSessionId`, which covers
`/clear`) and requires the caller to own it; otherwise `404` (same answer for
missing and not owned).

- `GET /api/live/team-skills` → `{ skills: [{ id, name, description, triggerPhrases: string[], content }] }`
  Active team skills of the caller's org; `content` is the rendered SKILL.md.
- `GET /api/live/nudge?session_id=` → `{ nudge: { rule, severity, message } | null }`
  Takes (returns and clears) the nudge the event ingestion recorded for that
  session; a nudge older than 2 minutes is dropped.
- `POST /api/live/next-prompts` `{ session_id, after?: string (≤ 4000), project?: string, limit?: 1-5 }`
  → `{ suggestions: [{ text, project }] }`
  With `after`: embed it, find similar human-origin turns (searchable scope,
  other sessions), and propose the next human turn of each such session when
  that turn had no tool failures and is not labelled `down`; ranked by
  similarity, `up` labels and merged PRs first. Without `after`: opening
  prompts of successful sessions in `project`. Empty when embeddings are down.
- `POST /api/live/labels` `{ session_id, turn_started_at: ISO, label: 'up'|'partial'|'down', source: 'explicit'|'implicit' }` → `{ ok: true }`
  The label belongs to the turn whose prompt started nearest `turn_started_at`
  (within 2 minutes), resolved at read time.
- `POST /api/live/vcs` `{ session_id, kind: 'commit'|'pr', ref, repo_remote? }` → `{ ok: true }`
  `ref` is a commit sha or a PR URL. Idempotent per (session, kind, ref).
- `GET /api/live/vcs/open-prs?repo_remote=` → `{ prs: [{ ref }] }`
  The caller's PR links in that repository whose state is unknown or open and
  were not checked in the last hour (at most 20).
- `POST /api/live/vcs/status` `{ ref, state: 'open'|'merged'|'closed', merged_at?, closed_at? }` → `{ ok: true }`
  Updates the caller's own links with that ref.

Storage: migration `055_live_outcomes.sql` adds `turn_labels` and
`session_vcs_links`, both cascading from `sessions`.
