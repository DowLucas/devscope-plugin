export type VcsLink = { kind: 'commit' | 'pr'; ref: string }

const COMMIT = /\bgit\s+(-C\s+\S+\s+)?commit\b/
const PR_CREATE = /\bgh\s+pr\s+create\b/
/** `git commit` prints `[branch 1a2b3c4] subject` (or `[main (root-commit) 1a2b3c4]`). */
const COMMIT_SHA = /^\[[^\]\n]*?\b([0-9a-f]{7,40})\]/m
const PR_URL = /https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/
const EXACT_PR_URL = new RegExp(`^${PR_URL.source}$`)

/**
 * Whether `ref` is exactly a GitHub PR URL. Refs come back from the backend
 * and become `gh` arguments, so nothing else (an option, a path) may pass.
 */
export const isPrUrl = (ref: string) => EXACT_PR_URL.test(ref)

/** A remote URL without embedded credentials, as session-start.sh sends it. */
export const withoutCredentials = (remote: string) => remote.replace(/:\/\/[^@/]+@/, '://')

/** The commit or PR a successful Bash call made, read from its output. */
export function linkFromBash(command: string, stdout: string): VcsLink | undefined {
  if (COMMIT.test(command)) {
    const sha = COMMIT_SHA.exec(stdout)?.[1]
    return sha ? { kind: 'commit', ref: sha } : undefined
  }
  if (PR_CREATE.test(command)) {
    const url = PR_URL.exec(stdout)?.[0]
    return url ? { kind: 'pr', ref: url } : undefined
  }
  return undefined
}

export function withTrailer(text: string, sessionId: string): string {
  const line = `DevScope-Session: ${sessionId}`
  if (text.includes(line)) return text
  return text ? `${text}\n${line}` : line
}

export type PrStatus = { state: 'open' | 'merged' | 'closed'; merged_at?: string; closed_at?: string }

/** `gh pr view --json state,mergedAt,closedAt` output, as the backend takes it. */
export function parseGhPr(json: string): PrStatus | undefined {
  try {
    const pr = JSON.parse(json) as { state?: string; mergedAt?: string | null; closedAt?: string | null }
    const state = pr.state?.toLowerCase()
    if (state !== 'open' && state !== 'merged' && state !== 'closed') return undefined
    return {
      state,
      ...(pr.mergedAt ? { merged_at: pr.mergedAt } : {}),
      ...(pr.closedAt ? { closed_at: pr.closedAt } : {}),
    }
  } catch {
    return undefined
  }
}
