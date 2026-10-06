import { describe, expect, test } from 'claude-code/testing'

import { parseConfig, readOptions, resolveConfig } from '../hooks/config'
import { implicitLabel, shouldAsk } from '../hooks/labels'
import { basename, nextPromptsBody } from '../hooks/suggestions'
import { matchSkill } from '../hooks/teamSkills'
import type { TeamSkill } from '../hooks/teamSkills'
import { linkFromBash, parseGhPr, withTrailer } from '../hooks/vcs'

const skill = (id: string, ...triggerPhrases: string[]): TeamSkill => ({
  id,
  name: id,
  description: '',
  triggerPhrases,
  content: `# ${id}`,
})

describe('config', () => {
  test('parses the Bash plugin config file', () => {
    const file = parseConfig('# comment\nDEVSCOPE_URL="https://ds.example"\nDEVSCOPE_API_KEY=abc\n\nDEVSCOPE_PRIVACY=\'private\'\n')
    expect(file).toEqual({ DEVSCOPE_URL: 'https://ds.example', DEVSCOPE_API_KEY: 'abc', DEVSCOPE_PRIVACY: 'private' })
  })

  test('the environment wins over the file, as in _helpers.sh', () => {
    const config = resolveConfig({ url: 'http://env/', privacy: undefined }, { DEVSCOPE_URL: 'http://file', DEVSCOPE_PRIVACY: 'open' })
    expect(config).toEqual({ url: 'http://env', apiKey: undefined, privacy: 'open' })
  })

  test('unknown privacy values fall back to standard', () => {
    expect(resolveConfig({ privacy: 'paranoid' }, {}).privacy).toBe('standard')
    expect(resolveConfig({}, {}).url).toBe('http://localhost:6767')
  })

  test('options default on, except the commit trailer', () => {
    expect(readOptions({})).toEqual({
      nextPrompts: true,
      teamSkills: true,
      stuckBand: true,
      outcomeLabels: true,
      commitLinks: true,
      commitTrailer: false,
    })
    expect(readOptions({ commitTrailer: true, nextPrompts: false }).commitTrailer).toBe(true)
  })
})

describe('labels', () => {
  test('complaints label the last turn down', () => {
    for (const reply of ["that didn't work", 'No, use the other file', 'still failing on CI', 'It still fails', 'revert that']) {
      expect(implicitLabel(reply)).toBe('down')
    }
  })

  test('praise labels it up', () => {
    for (const reply of ['thanks!', 'Perfect, now add tests', 'LGTM', 'it works']) {
      expect(implicitLabel(reply)).toBe('up')
    }
  })

  test('ordinary prompts carry no label', () => {
    for (const reply of ['now add a test for the parser', 'nothing changed in the api?', 'notice the header']) {
      expect(implicitLabel(reply)).toBeUndefined()
    }
  })

  test('asks only after a long or busy turn, at most every 30 minutes', () => {
    const now = 10 * 60 * 60_000
    expect(shouldAsk({ durationMs: 5_000, toolCalls: 2 }, 0, now)).toBe(false)
    expect(shouldAsk({ durationMs: 180_000, toolCalls: 2 }, 0, now)).toBe(true)
    expect(shouldAsk({ durationMs: 5_000, toolCalls: 20 }, 0, now)).toBe(true)
    expect(shouldAsk({ durationMs: 180_000, toolCalls: 2 }, now - 60_000, now)).toBe(false)
  })
})

describe('team skills', () => {
  const skills = [skill('release', 'cut a release'), skill('short', 'test'), skill('deploy', 'deploy to staging', 'deploy')]

  test('matches a trigger phrase as whole words, longest first', () => {
    expect(matchSkill('Please cut a release for 2.0', skills)?.id).toBe('release')
    expect(matchSkill('can you DEPLOY TO STAGING?', skills)?.id).toBe('deploy')
  })

  test('ignores short phrases and partial words', () => {
    expect(matchSkill('write a test', skills)).toBeUndefined()
    expect(matchSkill('cut a releases list', skills)).toBeUndefined()
  })
})

describe('vcs', () => {
  test('reads the commit sha from git commit output', () => {
    expect(linkFromBash('git commit -m "x"', '[main 1a2b3c4] x\n 1 file changed')).toEqual({ kind: 'commit', ref: '1a2b3c4' })
    expect(linkFromBash('git -C sub commit -am y', '[main (root-commit) abcdef0] y')).toEqual({ kind: 'commit', ref: 'abcdef0' })
  })

  test('reads the PR URL from gh pr create output', () => {
    expect(linkFromBash('gh pr create --fill', 'https://github.com/DowLucas/devscope/pull/77\n')).toEqual({
      kind: 'pr',
      ref: 'https://github.com/DowLucas/devscope/pull/77',
    })
  })

  test('ignores other commands and failed output', () => {
    expect(linkFromBash('git status', '[main 1a2b3c4] x')).toBeUndefined()
    expect(linkFromBash('git commit -m x', 'nothing to commit, working tree clean')).toBeUndefined()
  })

  test('adds the trailer once', () => {
    expect(withTrailer('Co-Authored-By: C', 's1')).toBe('Co-Authored-By: C\nDevScope-Session: s1')
    expect(withTrailer(withTrailer('', 's1'), 's1')).toBe('DevScope-Session: s1')
  })

  test('maps gh pr view output', () => {
    expect(parseGhPr('{"state":"MERGED","mergedAt":"2026-10-01T10:00:00Z","closedAt":"2026-10-01T10:00:00Z"}')).toEqual({
      state: 'merged',
      merged_at: '2026-10-01T10:00:00Z',
      closed_at: '2026-10-01T10:00:00Z',
    })
    expect(parseGhPr('{"state":"OPEN","mergedAt":null,"closedAt":null}')).toEqual({ state: 'open' })
    expect(parseGhPr('not json')).toBeUndefined()
  })
})

describe('suggestions', () => {
  test('builds the next-prompts request', () => {
    expect(nextPromptsBody({ sessionId: 's', project: 'p' })).toEqual({ session_id: 's', project: 'p', limit: 1 })
    expect(nextPromptsBody({ sessionId: 's', project: 'p', after: 'x'.repeat(5000) }).after?.length).toBe(4000)
    expect(basename('/home/me/devscope/')).toBe('devscope')
  })
})
