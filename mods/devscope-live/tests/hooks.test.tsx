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

function setup(on: On, env: Record<string, string> = {}) {
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
  test('proposes the next prompt that worked after a similar one', async ($, on) => {
    const { clock, seen } = setup(on)
    const calls = backend(on, {
      'POST /api/live/next-prompts': { suggestions: [{ text: 'now run the integration tests', project: 'devscope' }] },
    })
    await $.prompt.submit(typed('add a migration for turn labels'))
    await $.turn.start({ text: '', turnId: 't1' })
    await $.turn.complete({ answer: 'Added.', durationMs: 5000, isAborted: false, turnId: 't1', reason: 'answer' })
    await clock.advance(1)

    expect(posts(calls, '/api/live/next-prompts')[0]?.body).toEqual({
      session_id: 'cc-session-1',
      project: 'devscope',
      after: 'add a migration for turn labels',
      limit: 1,
    })
    expect(seen.suggested).toEqual(['now run the integration tests'])
  })

  test('replaces the engine guess with the fresh team suggestion', async ($, on) => {
    const { clock, seen } = setup(on)
    backend(on, { 'POST /api/live/next-prompts': { suggestions: [{ text: 'team step', project: 'devscope' }] } })
    await $.prompt.submit(typed('something'))
    await $.turn.complete({ answer: '', durationMs: 1000, isAborted: false, turnId: 't1', reason: 'answer' })
    await clock.advance(1)
    await $.prompt.suggest({ text: 'engine guess', origin: { kind: 'suggestion' } })
    expect(seen.suggested.at(-1)).toBe('team step')
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
