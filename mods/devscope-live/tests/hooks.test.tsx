import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const PLUGIN = 'devscope-live'
const URL_BASE = 'http://devscope.test'
const SESSION = { cwd: '/work/devscope', surface: 'terminal' as const, isInteractive: true }
const ABOVE_PROMPT = { plugin: PLUGIN, component: 'AbovePrompt' as const, props: { hasSurvey: false, isWorking: false, maxRows: 4, bodyColumns: 120, scroll: { offset: 0, bodyRows: 40 }, view: {} } }

type Call = { method: string; path: string; body: Record<string, unknown> | undefined }

/** A DevScope backend under the plugin: answers by "METHOD /path", records every call. */
function backend(on: On, answers: Record<string, unknown> = {}): Call[] {
  const calls: Call[] = []
  on('http.fetch', (_$, e) => {
    const url = new URL(e.url)
    const method = e.init?.method ?? 'GET'
    calls.push({ method, path: url.pathname + url.search, body: e.init?.body ? JSON.parse(e.init.body) : undefined })
    const answer = answers[`${method} ${url.pathname}`] ?? { ok: true }
    return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify(answer) } }
  })
  return calls
}

/** What reached the engine beneath the plugin. */
type Seen = { submitted: string[]; suggested: string[]; aborted: string[] }

/** Files the plugin may read, by absolute path; a missing one rejects. */
type Files = Record<string, string>

function setup(on: On, env: Record<string, string> = {}, files: Files = {}) {
  mock.env(on, { DEVSCOPE_URL: URL_BASE, DEVSCOPE_API_KEY: 'key', HOME: '/home/test', ...env })
  mock.store(on)
  const seen: Seen = { submitted: [], suggested: [], aborted: [] }
  // The engine beneath the plugin: each event's own behaviour, minimally.
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('prompt.submit', (_$, e) => {
    seen.submitted.push(e.text)
    return { text: e.text, context: e.context }
  })
  on('prompt.suggest', (_$, e) => {
    seen.suggested.push(e.text)
    return { isShown: true }
  })
  on('turn.abort', (_$, e) => {
    seen.aborted.push(e.turnId)
    return { value: undefined }
  })
  on('session.cwd', () => ({ value: '/work/devscope' }))
  // No ~/.config/devscope/config: the environment above is the whole config.
  on('fs.exists', () => ({ value: false }))
  on('fs.read', (_$, e) => (e.path in files ? { value: files[e.path] } : { deny: 'ENOENT' }))
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('ui.render', ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
  on('session.id', () => ({ value: 'cc-session-1' }))
  on('session.repo', () => ({ value: { root: '/work/devscope', remote: 'git@github.com:acme/devscope.git', internal: false, name: null } }))
  return { clock: mock.clock(on), seen }
}

/** A prompt the person typed into the composer. */
const typed = (text: string) => ({ text, origin: { kind: 'composer' as const }, wait: false })

const posts = (calls: Call[], path: string) => calls.filter(c => c.method === 'POST' && c.path === path)

describe('#9 commit trailer', () => {
  test('is off by default', async ($, on) => {
    setup(on)
    on('attribution.text', (_$, e) => ({ text: e.text }))
    expect((await $.attribution.text({ kind: 'commit', text: 'Co-Authored-By: Claude' })).text).toBe('Co-Authored-By: Claude')
  })

  test('adds the DevScope-Session line when turned on', { options: { commitTrailer: true } }, async ($, on) => {
    setup(on)
    on('attribution.text', (_$, e) => ({ text: e.text }))
    expect((await $.attribution.text({ kind: 'pr', text: 'Generated with Claude Code' })).text).toBe(
      'Generated with Claude Code\nDevScope-Session: cc-session-1',
    )
  })

  test('stays off in private mode', { options: { commitTrailer: true } }, async ($, on) => {
    setup(on, { DEVSCOPE_PRIVACY: 'private' })
    on('attribution.text', (_$, e) => ({ text: e.text }))
    expect((await $.attribution.text({ kind: 'commit', text: 'x' })).text).toBe('x')
  })
})

describe('#9 commit and PR links', () => {
  test('records the commit a successful git commit made', async ($, on) => {
    const { clock, seen } = setup(on)
    const calls = backend(on)
    on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '[main 1a2b3c4] add parser\n', stderr: '' } }))
    await $.tool.call({ tool: 'Bash', command: 'git commit -m "add parser"' })
    await clock.advance(1)
    expect(posts(calls, '/api/live/vcs')[0]?.body).toEqual({
      session_id: 'cc-session-1',
      kind: 'commit',
      ref: '1a2b3c4',
      repo_remote: 'git@github.com:acme/devscope.git',
    })
  })

  test('settles open PRs with gh at session start', async ($, on) => {
    const { clock, seen } = setup(on)
    const calls = backend(on, {
      'GET /api/live/vcs/open-prs': { prs: [{ ref: '--repo=evil/x' }, { ref: 'https://github.com/acme/devscope/pull/7' }] },
    })
    const ran: string[][] = []
    on('process.run', (_$, e) => (ran.push([...e.argv]), {
      value: {
        exitCode: 0,
        stdout: e.argv.includes('https://github.com/acme/devscope/pull/7') ? '{"state":"MERGED","mergedAt":"2026-10-01T10:00:00Z","closedAt":null}' : '',
        stderr: '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }))
    await $.session.start({ ...SESSION, isInteractive: false })
    await clock.advance(1)
    // A ref that isn't exactly a PR URL never reaches gh.
    expect(ran.map(argv => argv[3])).toEqual(['https://github.com/acme/devscope/pull/7'])
    expect(posts(calls, '/api/live/vcs/status')[0]?.body).toEqual({
      ref: 'https://github.com/acme/devscope/pull/7',
      state: 'merged',
      merged_at: '2026-10-01T10:00:00Z',
    })
  })
})

describe('#8 outcome labels', () => {
  test('a complaint labels the previous turn down', async ($, on) => {
    const { clock, seen } = setup(on)
    const calls = backend(on)
    await clock.set(Date.parse('2026-10-06T10:00:00Z'))
    await $.prompt.submit(typed('add a parser for the config file'))
    await clock.advance(60_000)
    await $.prompt.submit(typed("that didn't work, the tests still fail"))
    await clock.advance(1)
    expect(posts(calls, '/api/live/labels')[0]?.body).toEqual({
      session_id: 'cc-session-1',
      turn_started_at: '2026-10-06T10:00:00.000Z',
      label: 'down',
      source: 'implicit',
    })
  })

  test('a long turn asks, and the answer is recorded', async ($, on) => {
    const { clock, seen } = setup(on)
    const calls = backend(on)
    await $.prompt.submit(typed('refactor the session store'))
    await $.turn.start({ text: 'refactor the session store', turnId: 't1' })
    await $.turn.complete({ answer: 'Done.', durationMs: 300_000, isAborted: false, turnId: 't1', reason: 'answer' })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: /did that work/ })).toBeDefined()
    await ui.press({ key: 'label-up' })
    expect(posts(calls, '/api/live/labels')[0]?.body).toMatchObject({ label: 'up', source: 'explicit' })
    expect(await ui.find({ key: 'label-up' })).toBeUndefined()
    await ui.unmount()
  })

  test('sends nothing in private mode', async ($, on) => {
    const { clock, seen } = setup(on, { DEVSCOPE_PRIVACY: 'private' })
    const calls = backend(on)
    await $.prompt.submit(typed('first'))
    await $.prompt.submit(typed("that didn't work"))
    await clock.advance(1)
    expect(posts(calls, '/api/live/labels')).toEqual([])
  })
})

describe('#6 stuck band', () => {
  test('shows the nudge after a failure and Keep going dismisses it', async ($, on) => {
    const { clock, seen } = setup(on)
    const calls = backend(on, {
      'GET /api/live/nudge': { nudge: { rule: 'repeated_failure', severity: 'warning', message: 'bun test has failed 3 times the same way.' } },
    })
    on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '', stderr: 'FAIL' }, isError: true }))
    await $.tool.call({ tool: 'Bash', command: 'bun test' })
    await clock.advance(2500)
    expect(calls.some(c => c.path === '/api/live/nudge?session_id=cc-session-1')).toBe(true)

    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface })
      expect(await ui.find({ type: 'Text', text: /failed 3 times/ })).toBeDefined()
      if (surface === 'desktop') await ui.press({ key: 'keep-going' })
      await ui.unmount()
    }
    const after = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await after.find({ key: 'step-back' })).toBeUndefined()
    await after.unmount()
  })

  test('checks once, after the last of a run of failures', async ($, on) => {
    const { clock } = setup(on)
    // The friction rule only trips on the third failure.
    let failures = 0
    const calls = backend(on)
    on('tool.call', { tool: 'Bash' }, () => {
      failures += 1
      return { result: { stdout: '', stderr: 'FAIL' }, isError: true }
    })
    for (let i = 0; i < 3; i++) {
      await $.tool.call({ tool: 'Bash', command: 'bun test' })
      await clock.advance(1000)
    }
    await clock.advance(2500)
    expect(failures).toBe(3)
    expect(calls.filter(c => c.path.startsWith('/api/live/nudge'))).toHaveLength(1)
  })

  test('Step back interrupts the turn and asks Claude to reassess', async ($, on) => {
    const { clock, seen } = setup(on)
    backend(on, { 'GET /api/live/nudge': { nudge: { rule: 'repeated_failure', severity: 'warning', message: 'stuck' } } })
    on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '', stderr: 'FAIL' }, isError: true }))
    await $.turn.start({ text: 'fix it', turnId: 't9' })
    await $.tool.call({ tool: 'Bash', command: 'bun test' })
    await clock.advance(2500)

    const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    await ui.press({ key: 'step-back' })
    expect(seen.aborted).toEqual(['t9'])
    expect(seen.submitted.at(-1)).toMatch(/^Stop retrying/)
    await ui.unmount()
  })
})

describe('#3 team skills', () => {
  const skills = {
    skills: [{ id: 'sk1', name: 'release-checklist', description: '', triggerPhrases: ['cut a release'], content: '# Release\n1. Bump versions' }],
  }

  test('offers a matching team skill once and attaches it when chosen', async ($, on) => {
    const { clock, seen } = setup(on)
    backend(on, { 'GET /api/live/team-skills': skills })
    let asked = 0
    on('tool.call', { tool: 'AskUserQuestion' }, (_$, e) => {
      asked += 1
      const question = e.questions[0]?.question ?? ''
      return { result: { questions: e.questions, answers: { [question]: 'Use it' } } }
    })
    await $.session.start(SESSION)
    await clock.advance(1)

    const first = await $.prompt.submit(typed('Please cut a release for 2.0'))
    expect('context' in first ? first.context?.some(c => c.includes('# Release')) : false).toBe(true)
    await $.prompt.submit(typed('cut a release again'))
    expect(asked).toBe(1)
  })
})

describe('#2 team prompts', () => {
  /** One answered turn after `prompt` in which Claude ran `tools` tool calls. */
  async function workedTurn($: any, prompt: string, opts: { answer?: string; tools?: number; id?: string } = {}) {
    await $.prompt.submit(typed(prompt))
    await $.turn.start({ text: '', turnId: opts.id ?? 't1' })
    for (let i = 0; i < (opts.tools ?? 1); i++) await $.tool.call({ tool: 'Bash', command: 'ls' })
    await $.turn.complete({ answer: opts.answer ?? 'Added.', durationMs: 5000, isAborted: false, turnId: opts.id ?? 't1', reason: 'answer' })
  }
  const okBash = (on: On) => on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '', stderr: '' }, isError: false }))

  test('proposes the next prompt that worked after a similar one', async ($, on) => {
    const { clock, seen } = setup(on)
    okBash(on)
    const calls = backend(on, {
      'POST /api/live/next-prompts': { suggestions: [{ text: 'run integration tests', project: 'devscope' }] },
    })
    await workedTurn($, 'add a migration for turn labels')
    await clock.advance(1)

    expect(posts(calls, '/api/live/next-prompts')[0]?.body).toEqual({
      session_id: 'cc-session-1',
      project: 'devscope',
      after: 'add a migration for turn labels',
      limit: 1,
    })
    expect(seen.suggested).toEqual(['run integration tests'])
  })

  test('replaces the engine guess with the fresh team suggestion', async ($, on) => {
    const { clock, seen } = setup(on)
    okBash(on)
    backend(on, { 'POST /api/live/next-prompts': { suggestions: [{ text: 'team step', project: 'devscope' }] } })
    await workedTurn($, 'something')
    await clock.advance(1)
    await $.prompt.suggest({ text: 'engine guess', origin: { kind: 'suggestion' } })
    expect(seen.suggested.at(-1)).toBe('team step')
  })

  test('never shows more than a few words, whatever the server sends', async ($, on) => {
    const { clock, seen } = setup(on)
    okBash(on)
    backend(on, {
      'POST /api/live/next-prompts': { suggestions: [{ text: 'please also update the docs and the changelog', project: 'devscope' }] },
    })
    await workedTurn($, 'fix it')
    await clock.advance(1)
    expect(seen.suggested).toEqual([])
  })

  test('stays quiet when Claude asked a question, or only talked', async ($, on) => {
    const { clock } = setup(on)
    okBash(on)
    const calls = backend(on, { 'POST /api/live/next-prompts': { suggestions: [{ text: 'push', project: 'devscope' }] } })
    await workedTurn($, 'fix it', { answer: 'Fixed the parser.\n\nShould I also update the docs?' })
    await clock.advance(1)
    await workedTurn($, 'what does this do', { tools: 0, id: 't2' })
    await clock.advance(1)
    expect(posts(calls, '/api/live/next-prompts')).toHaveLength(0)
  })

  test('pauses for 30 minutes after three suggestions in a row are typed over', async ($, on) => {
    const { clock, seen } = setup(on)
    okBash(on)
    const calls = backend(on, { 'POST /api/live/next-prompts': { suggestions: [{ text: 'push', project: 'devscope' }] } })
    for (let i = 0; i < 4; i++) {
      await workedTurn($, `change ${i}`, { id: `t${i}` })
      await clock.advance(1)
    }
    // Shown after turns 0-2; each typed over by the next prompt; none after turn 3.
    expect(posts(calls, '/api/live/next-prompts')).toHaveLength(3)
    await clock.advance(30 * 60 * 1000)
    await workedTurn($, 'push', { id: 't9' })
    await clock.advance(1)
    expect(posts(calls, '/api/live/next-prompts')).toHaveLength(4)
    expect(seen.suggested).toHaveLength(4)
  })
})

describe('privacy', () => {
  test('a config file that exists but cannot be read is taken as private', async ($, on) => {
    mock.env(on, { DEVSCOPE_URL: URL_BASE, DEVSCOPE_API_KEY: 'key', HOME: '/home/test' })
    mock.store(on)
    on('session.start', (_$, e) => ({ cwd: e.cwd }))
    on('prompt.submit', (_$, e) => ({ text: e.text, context: e.context }))
    on('session.id', () => ({ value: 'cc-session-1' }))
    on('fs.exists', () => ({ value: true }))
    on('fs.read', () => ({ deny: 'permission denied' }))
    const calls = backend(on)
    const clock = mock.clock(on)
    await $.prompt.submit(typed('first'))
    await $.prompt.submit(typed("that didn't work"))
    await clock.advance(10)
    expect(posts(calls, '/api/live/labels')).toEqual([])
  })
})

describe('rate limit', () => {
  test('a write retries once after a 429', async ($, on) => {
    const { clock } = setup(on)
    let attempts = 0
    on('http.fetch', () => {
      attempts += 1
      return attempts === 1
        ? { value: { status: 429, ok: false, headers: {}, text: '' } }
        : { value: { status: 200, ok: true, headers: {}, text: '{"ok":true}' } }
    })
    await $.prompt.submit(typed('first'))
    await $.prompt.submit(typed("that didn't work"))
    await clock.advance(2000)
    expect(attempts).toBe(2)
  })
})

describe('fail open', () => {
  test('with the backend down, prompts, tools and turns are untouched', { options: { commitTrailer: true } }, async ($, on) => {
    const { clock, seen } = setup(on)
    on('http.fetch', () => {
      throw new Error('connect ECONNREFUSED')
    })
    on('tool.call', { tool: 'Bash' }, () => ({ result: { stdout: '', stderr: 'FAIL' }, isError: true }))
    await $.session.start(SESSION)
    const submitted = await $.prompt.submit(typed('cut a release please'))
    expect('text' in submitted ? submitted.text : undefined).toBe('cut a release please')
    await $.tool.call({ tool: 'Bash', command: 'bun test' })
    await $.turn.complete({ answer: 'x', durationMs: 999_000, isAborted: false, turnId: 't1', reason: 'answer' })
    await clock.advance(10_000)

    expect(seen.suggested).toEqual([])
    const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await ui.find({ key: 'step-back' })).toBeUndefined()
    await ui.unmount()
  })
})

describe('voice progress bar', () => {
  const PROGRESS = '/home/test/.cache/devscope/voice/progress.json'
  const progress = (at: number, over: Record<string, unknown> = {}) =>
    JSON.stringify({ kind: 'explain', project: 'plugin', phase: 'speaking', piece: 1, pieces: 4, pieceMs: 10_000, at, pid: 4242, ...over })
  const run = (on: On) => {
    const ran: string[][] = []
    on('process.run', (_$, e) => (ran.push([...e.argv]), {
      value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    }))
    return ran
  }

  test('shows while the speaker speaks, and Stop ends its process group', async ($, on) => {
    const files: Files = {}
    const { clock } = setup(on, {}, files)
    const ran = run(on)
    await $.session.start(SESSION)
    files[PROGRESS] = progress(clock.now())
    await clock.advance(1000)

    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface })
      expect(await ui.find({ type: 'Text', text: 'plugin · explaining 2/4' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /\u283f/ })).toBeDefined()
      expect(await ui.find({ key: 'voice-stop' })).toBeDefined()
      await ui.unmount()
    }

    const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    await ui.press({ key: 'voice-stop' })
    expect(ran).toEqual([['kill', '-TERM', '--', '-4242']])
    await ui.unmount()
  })

  test('shows the bar only in the speaking session; other windows get a dimmed line', async ($, on) => {
    const files: Files = {}
    const { clock } = setup(on, {}, files)
    await $.session.start(SESSION)
    const own = 'cc-session-1' // the test engine's session id

    files[PROGRESS] = progress(clock.now(), { sessionId: own })
    await clock.advance(1000)
    let ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await ui.find({ key: 'voice-stop' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^🔊/ })).toBeUndefined()
    await ui.unmount()

    files[PROGRESS] = progress(clock.now(), { sessionId: 'some-other-session', kind: 'reply', project: 'api, rate limiter fix' })
    await clock.advance(1000)
    ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: '🔊 api, rate limiter fix · reading the summary 2/4' })).toBeDefined()
    expect(await ui.find({ key: 'voice-stop' })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /\u283f/ })).toBeUndefined()
    await ui.unmount()
  })

  test('animates while the audio is made, and goes away when the speaker is done', async ($, on) => {
    const files: Files = {}
    const { clock } = setup(on, {}, files)
    await $.session.start(SESSION)
    files[PROGRESS] = progress(clock.now(), { phase: 'voicing', pieces: 4, pieceMs: 0 })
    await clock.advance(1000)
    await clock.advance(6 * 120)
    const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: 'plugin · creating audio' })).toBeDefined()
    await ui.unmount()

    delete files[PROGRESS]
    await clock.advance(120)
    const after = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await after.find({ key: 'voice-stop' })).toBeUndefined()
    await after.unmount()
  })

  test('ignores a file a killed speaker left behind', async ($, on) => {
    const files: Files = {}
    const { clock } = setup(on, {}, files)
    await clock.advance(120_000)
    files[PROGRESS] = progress(clock.now() - 60_000)
    await $.session.start(SESSION)
    await clock.advance(1000)
    const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await ui.find({ key: 'voice-stop' })).toBeUndefined()
    await ui.unmount()
  })

  test('stays off when turned off', { options: { voiceProgress: false } }, async ($, on) => {
    const files: Files = {}
    const { clock } = setup(on, {}, files)
    await $.session.start(SESSION)
    files[PROGRESS] = progress(clock.now())
    await clock.advance(1000)
    const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await ui.find({ key: 'voice-stop' })).toBeUndefined()
    await ui.unmount()
  })

  test('stays off in headless sessions', async ($, on) => {
    const files: Files = {}
    const { clock } = setup(on, {}, files)
    await $.session.start({ ...SESSION, isInteractive: false })
    files[PROGRESS] = progress(clock.now())
    await clock.advance(1000)
    const ui = await $.ui.mount({ ...ABOVE_PROMPT, surface: 'terminal' })
    expect(await ui.find({ key: 'voice-stop' })).toBeUndefined()
    await ui.unmount()
  })
})
