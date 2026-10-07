import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { Band, StuckNudge, VoiceView } from '../types'
import { UNREADABLE_CONFIG, parseConfig, readOptions, resolveConfig } from './config'
import type { Config, Options } from './config'
import { implicitLabel, shouldAsk } from './labels'
import type { Label } from './labels'
import { STEP_BACK_PROMPT, afterPrompt, basename, fitsSuggestion, nextPromptsBody, shouldSuggestAfter } from './suggestions'
import type { Suggestion } from './suggestions'
import { USE_IT, matchSkill, skillContext, skillLabel } from './teamSkills'
import type { TeamSkill } from './teamSkills'
import { isPrUrl, linkFromBash, parseGhPr, withTrailer, withoutCredentials } from './vcs'
import { barCells, fraction, isStale, parseProgress, runs, voiceLabel } from './voiceBar'

const band = atom({ plugin: 'devscope-live', key: 'band' } as const, null as Band)
const voice = atom({ plugin: 'devscope-live', key: 'voice' } as const, null as VoiceView)

/** `$.http.fetch` has no timeout of its own; past this a request is given up on. */
const REQUEST_TIMEOUT_MS = 5000
/** Better Auth's per-key window resets once the key has been idle a full second. */
const RATE_LIMIT_RETRY_MS = 1500
/** The Bash plugin posts the failure event in the background; give it time to land. */
const NUDGE_DELAY_MS = 2500
/** A team suggestion replaces the engine's own guess for this long after it arrives. */
const SUGGESTION_FRESH_MS = 60_000
const SKILLS_CACHE_MS = 6 * 60 * 60 * 1000
const PR_CHECK_MS = 6 * 60 * 60 * 1000
/** How often to look for speech while there is none, and to redraw while there is. */
const VOICE_IDLE_MS = 1000
const VOICE_FRAME_MS = 120

const iso = (ms: number) => new Date(ms).toISOString()

// ---- DevScope settings and backend (fail open: any problem is `undefined`) ----

let configPromise: Promise<Config> | undefined

async function readConfig($: EngineInterface): Promise<Config> {
  const env = {
    url: await $.env.get('DEVSCOPE_URL'),
    apiKey: await $.env.get('DEVSCOPE_API_KEY'),
    privacy: await $.env.get('DEVSCOPE_PRIVACY'),
  }
  const configHome =
    (await $.env.get('XDG_CONFIG_HOME')) || `${(await $.env.get('HOME')) ?? ''}/.config`
  const path = `${configHome}/devscope/config`
  // No file means defaults. A file that exists but can't be read might say
  // `private`, so it is taken to (the environment still wins, as in bash).
  const exists = await $.fs.exists(path).catch(() => true)
  const file = exists ? await $.fs.read(path).then(parseConfig, () => UNREADABLE_CONFIG) : {}
  return resolveConfig(env, file)
}

function config($: EngineInterface): Promise<Config> {
  return (configPromise ??= readConfig($))
}
async function isPrivate($: EngineInterface): Promise<boolean> {
  return (await config($)).privacy === 'private'
}

async function request<T>($: EngineInterface, method: 'GET' | 'POST', path: string, body?: unknown) {
  try {
    const { url, apiKey } = await config($)
    const headers: Record<string, string> = { 'x-requested-with': 'devscope-live' }
    if (apiKey) headers['x-api-key'] = apiKey
    if (body !== undefined) headers['content-type'] = 'application/json'
    const send = () =>
      Promise.race([
        $.http.fetch(`${url}${path}`, {
          method,
          headers,
          body: body === undefined ? undefined : JSON.stringify(body),
        }),
        $.clock.sleep(REQUEST_TIMEOUT_MS).then(() => undefined),
      ])
    let response = await send()
    // The API key's rate limit is shared with the Bash plugin's events: a write
    // waits out the window and tries once more; a read just goes without.
    if (response?.status === 429 && method === 'POST') {
      await $.clock.sleep(RATE_LIMIT_RETRY_MS)
      response = await send()
    }
    return response?.ok ? (JSON.parse(response.text) as T) : undefined
  } catch {
    return undefined
  }
}

// ---- What this module knows of the session (a reload starts it over) ----

let options: Options = readOptions({})

const turn = {
  runningId: undefined as string | undefined,
  startedAt: undefined as string | undefined,
  lastPrompt: undefined as string | undefined,
  toolCalls: 0,
}
let skills: TeamSkill[] = []
const offered = new Set<string>()
let lastAskAt = Number.NEGATIVE_INFINITY
let suggestion: { text: string; at: number } | undefined
/** Suggestions typed over in a row, and until when suggestions are paused. */
let suggestState = { ignored: 0, pausedUntil: Number.NEGATIVE_INFINITY }
let nudgeCheck: Timer | undefined
let voiceIdle: Timer | undefined
let voiceFrames: Timer | undefined

// ---- #3 team skills ----

async function loadTeamSkills($: EngineInterface): Promise<TeamSkill[]> {
  const now = await $.clock.now()
  const cached = (await $.store.get('teamSkills')) as { at: number; skills: TeamSkill[] } | undefined
  if (cached && now - cached.at < SKILLS_CACHE_MS) return cached.skills
  const fresh = await request<{ skills: TeamSkill[] }>($, 'GET', '/api/live/team-skills')
  if (!Array.isArray(fresh?.skills)) return cached?.skills ?? []
  await $.store.set('teamSkills', { at: now, skills: fresh.skills })
  return fresh.skills
}

/** True only when the person picked "Use it"; dismissed or headless is a no. */
async function offerSkill($: EngineInterface, skill: TeamSkill): Promise<boolean> {
  try {
    return (await $.ui.ask(`Team skill "${skillLabel(skill)}" covers this. Use it?`, [USE_IT, 'Not now'])) === USE_IT
  } catch {
    return false
  }
}

// ---- #2 team prompts ----

async function proposeNextPrompt($: EngineInterface, after: string | undefined) {
  const body = nextPromptsBody({
    sessionId: await $.session.id(),
    project: basename(await $.session.cwd()),
    after,
  })
  const response = await request<{ suggestions: Suggestion[] }>($, 'POST', '/api/live/next-prompts', body)
  const text = Array.isArray(response?.suggestions) ? response.suggestions[0]?.text?.trim() : undefined
  if (!text || !fitsSuggestion(text)) return
  suggestion = { text, at: await $.clock.now() }
  await $.prompt.suggest({ text }).catch(() => undefined)
}

// ---- #6 stuck band ----

async function showPendingNudge($: EngineInterface) {
  const sessionId = encodeURIComponent(await $.session.id())
  const response = await request<{ nudge: StuckNudge | null }>($, 'GET', `/api/live/nudge?session_id=${sessionId}`)
  const nudge = response?.nudge
  if (nudge) await update($, band, (): Band => ({ kind: 'stuck', nudge }))
}

async function abortRunningTurn($: EngineInterface) {
  if (turn.runningId) await $.turn.abort({ turnId: turn.runningId }).catch(() => undefined)
}

// ---- #8 outcome labels ----

async function sendLabel($: EngineInterface, turnStartedAt: string, label: Label, source: 'explicit' | 'implicit') {
  await request($, 'POST', '/api/live/labels', {
    session_id: await $.session.id(),
    turn_started_at: turnStartedAt,
    label,
    source,
  })
}

// ---- #9 session ↔ commit links ----

async function repoRemote($: EngineInterface): Promise<string | undefined> {
  const remote = (await $.session.repo())?.remote
  return remote ? withoutCredentials(remote) : undefined
}

/**
 * Settles the state of this repository's open PRs that past sessions made,
 * with the person's own `gh`, at most every 6 hours per repository. Silent
 * on any failure (no `gh`, not logged in, no network).
 */
async function resolvePrs($: EngineInterface, remote: string) {
  const now = await $.clock.now()
  const checked = ((await $.store.get('prCheckAt')) ?? {}) as Record<string, number>
  if (now - (checked[remote] ?? Number.NEGATIVE_INFINITY) < PR_CHECK_MS) return
  await $.store.set('prCheckAt', { ...checked, [remote]: now })

  const open = await request<{ prs: { ref: string }[] }>(
    $,
    'GET',
    `/api/live/vcs/open-prs?repo_remote=${encodeURIComponent(remote)}`,
  )
  for (const { ref } of Array.isArray(open?.prs) ? open.prs : []) {
    if (typeof ref !== 'string' || !isPrUrl(ref)) continue
    const view = await $.process
      .run(['gh', 'pr', 'view', ref, '--json', 'state,mergedAt,closedAt'], { timeoutMs: 15_000 })
      .catch(() => undefined)
    if (!view) return
    const status = view.exitCode === 0 ? parseGhPr(view.stdout) : undefined
    if (status) await request($, 'POST', '/api/live/vcs/status', { ref, ...status })
  }
}

// ---- Voice progress bar (the Bash plugin's speaker writes progress.json) ----

async function voiceProgressPath($: EngineInterface): Promise<string> {
  return `${(await $.env.get('HOME')) ?? ''}/.cache/devscope/voice/progress.json`
}

/** Reads the speaker's progress into the bar; false when nothing is speaking. */
async function pollVoice($: EngineInterface): Promise<boolean> {
  const text = await $.fs.read(await voiceProgressPath($)).catch(() => undefined)
  const progress = typeof text === 'string' ? parseProgress(text) : undefined
  if (!progress || isStale(progress, await $.clock.now())) {
    if ((await read($, voice)) !== null) await update($, voice, () => null)
    return false
  }
  await update($, voice, (current): VoiceView => ({ progress, frame: (current?.frame ?? 0) + 1 }))
  return true
}

/** Looks once a second; while something speaks, redraws a few times a second. */
function watchVoice($: EngineInterface) {
  voiceIdle?.cancel()
  voiceIdle = $.clock.every(VOICE_IDLE_MS, () => {
    if (voiceFrames) return
    void pollVoice($).then(active => {
      if (!active || voiceFrames) return
      voiceFrames = $.clock.every(VOICE_FRAME_MS, () => {
        void pollVoice($).then(still => {
          if (still) return
          voiceFrames?.cancel()
          voiceFrames = undefined
        })
      })
    })
  })
}

function stopWatchingVoice() {
  voiceIdle?.cancel()
  voiceFrames?.cancel()
  voiceIdle = voiceFrames = undefined
}

/** Ends the speaker's process group (the player with it), as /devscope:voice stop does. */
async function stopSpeaking($: EngineInterface, pid: number) {
  const run = (argv: string[]) => $.process.run(argv, { timeoutMs: 2000 }).catch(() => undefined)
  const group = await run(['kill', '-TERM', '--', `-${pid}`])
  if (group?.exitCode !== 0) await run(['kill', '-TERM', String(pid)])
  await update($, voice, () => null)
}

export const register: Register = (on, pluginOptions) => {
  options = readOptions(pluginOptions)

  // ---- Hooks ----

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    if (options.voiceProgress && e.isInteractive) watchVoice($)
    // Network work never holds up the first prompt.
    $.clock.after(0, () => {
      void (async () => {
        if (options.teamSkills) skills = await loadTeamSkills($)
        if (await isPrivate($)) return
        const remote = await repoRemote($)
        if (options.commitLinks && remote) await resolvePrs($, remote)
        if (options.nextPrompts && e.isInteractive && (await $.clock.now()) >= suggestState.pausedUntil) {
          await proposeNextPrompt($, undefined)
        }
      })()
    })
    return started
  })

  on('session.end', async ($, e, next) => {
    // A /clear ends the conversation without a new session.start.
    Object.assign(turn, { runningId: undefined, startedAt: undefined, lastPrompt: undefined, toolCalls: 0 })
    offered.clear()
    suggestion = undefined
    await update($, band, () => null)
    stopWatchingVoice()
    await update($, voice, () => null)
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind !== 'composer') return next(e)

    // The reply labels the turn it answers.
    if (options.outcomeLabels && turn.startedAt && !(await isPrivate($))) {
      const label = implicitLabel(e.text)
      if (label) void sendLabel($, turn.startedAt, label, 'implicit')
    }
    if (suggestion) suggestState = afterPrompt(suggestState, e.text, suggestion.text, await $.clock.now())
    Object.assign(turn, { startedAt: iso(await $.clock.now()), lastPrompt: e.text, toolCalls: 0 })
    suggestion = undefined
    await update($, band, current => (current?.kind === 'label' ? null : current))

    const skill = options.teamSkills ? matchSkill(e.text, skills) : undefined
    if (skill && !offered.has(skill.id)) {
      offered.add(skill.id)
      if (await offerSkill($, skill)) {
        return next({ ...e, context: [...(e.context ?? []), skillContext(skill)] })
      }
    }
    return next(e)
  }).catch(($, e, next) => next(e)) // fail open; replays a settled `next`, so nothing runs twice

  on('turn.start', ($, e, next) => {
    turn.runningId = e.turnId
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (ran.deny !== undefined) return ran
    turn.toolCalls += 1

    // One check, after the last of a run of failures: the rule that raises
    // the nudge trips on a later failure than the first.
    if (ran.isError === true && options.stuckBand) {
      nudgeCheck?.cancel()
      nudgeCheck = $.clock.after(NUDGE_DELAY_MS, () => {
        nudgeCheck = undefined
        void showPendingNudge($)
      })
    }

    if (e.tool === 'Bash' && ran.isError !== true && options.commitLinks) {
      const stdout = (ran.result as { stdout?: string } | undefined)?.stdout ?? ''
      const link = linkFromBash(e.command, stdout)
      if (link) {
        void (async () => {
          if (await isPrivate($)) return
          await request($, 'POST', '/api/live/vcs', {
            session_id: await $.session.id(),
            ...link,
            repo_remote: await repoRemote($),
          })
        })()
      }
    }
    return ran
  }).catch(($, e, next) => next(e)) // fail open; replays a settled `next`, so nothing runs twice

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (e.agentId !== undefined) return done
    turn.runningId = undefined
    if (e.isAborted || e.reason !== 'answer') return done

    const { startedAt, lastPrompt, toolCalls } = turn
    $.clock.after(0, () => {
      void (async () => {
        if (await isPrivate($)) return
        const now = await $.clock.now()
        if (options.outcomeLabels && startedAt && shouldAsk({ durationMs: e.durationMs, toolCalls }, lastAskAt, now)) {
          lastAskAt = now
          const ask: Band = { kind: 'label', turnStartedAt: startedAt }
          await update($, band, current => current ?? ask)
        }
        if (
          options.nextPrompts &&
          lastPrompt &&
          shouldSuggestAfter({ answer: e.answer, toolCalls }) &&
          now >= suggestState.pausedUntil
        ) {
          await proposeNextPrompt($, lastPrompt)
        }
      })()
    })
    return done
  })

  // The team's proven next step wins over the engine's own guess.
  on('prompt.suggest', async ($, e, next) => {
    if (e.origin.kind !== 'suggestion' || !suggestion) return next(e)
    if ((await $.clock.now()) - suggestion.at > SUGGESTION_FRESH_MS) return next(e)
    return next({ ...e, text: suggestion.text })
  })

  on('attribution.text', async ($, e, next) => {
    const result = await next(e)
    if (!options.commitTrailer || (e.kind !== 'commit' && e.kind !== 'pr')) return result
    if (await isPrivate($)) return result
    return { text: withTrailer(result.text, await $.session.id()) }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const current = await read($, band)
    const speaking = await read($, voice)
    if ((current === null && speaking === null) || e.props.hasSurvey) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const clear = () => update($, band, () => null)

    const voiceRow = speaking ? (
      <Box key="voice" gap={1}>
        <Box>
          {runs(barCells(fraction(speaking.progress, await $.clock.now()), speaking.frame)).map((run, i) => (
            <Text key={`voice-bar-${i}`} color={run.color}>
              {run.char}
            </Text>
          ))}
        </Box>
        <Text dimColor>{voiceLabel(speaking.progress)}</Text>
        <Button key="voice-stop" label="Stop" dimColor onPress={() => stopSpeaking($, speaking.progress.pid)} />
      </Box>
    ) : null

    let bandRow = null
    if (current?.kind === 'stuck') {
      bandRow = (
        <Box key="band" flexDirection="column">
          <Text color="warning">DevScope: {current.nudge.message}</Text>
          <Box gap={1}>
            <Button
              key="step-back"
              label="Step back"
              variant="primary"
              onPress={async () => {
                await clear()
                await abortRunningTurn($)
                await $.prompt.submit({ text: STEP_BACK_PROMPT }).catch(() => undefined)
              }}
            />
            <Button
              key="stop"
              label="Stop"
              onPress={async () => {
                await clear()
                await abortRunningTurn($)
              }}
            />
            <Button key="keep-going" label="Keep going" onPress={clear} />
          </Box>
        </Box>
      )
    } else if (current?.kind === 'label') {
      const answer = (label: Label) => async () => {
        await clear()
        await sendLabel($, current.turnStartedAt, label, 'explicit')
        $.ui.toast('DevScope: thanks, noted.')
      }
      bandRow = (
        <Box key="band" gap={1}>
          <Text dimColor>DevScope: did that work?</Text>
          <Button key="label-up" label="👍 Yes" onPress={answer('up')} />
          <Button key="label-partial" label="Partly" onPress={answer('partial')} />
          <Button key="label-down" label="👎 No" onPress={answer('down')} />
          <Button key="label-dismiss" label="Skip" dimColor onPress={clear} />
        </Box>
      )
    }

    if (voiceRow && bandRow) {
      return (
        <Box flexDirection="column">
          {voiceRow}
          {bandRow}
        </Box>
      )
    }
    return voiceRow ?? bandRow ?? next(e)
  })
}
