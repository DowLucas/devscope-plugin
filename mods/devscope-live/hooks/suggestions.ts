/** One proposal from `POST /api/live/next-prompts`. */
export type Suggestion = {
  text: string
  project: string | null
  sessionTitle: string | null
  toolCalls: number
  label: string | null
}

/**
 * The request for the next prompt that worked after a similar one (`after`),
 * or, with no `after` yet, a prompt that opened a successful session in
 * `project`.
 */
export function nextPromptsBody(input: { sessionId: string; project: string; after?: string }) {
  return {
    session_id: input.sessionId,
    project: input.project,
    ...(input.after ? { after: input.after.slice(0, 4000) } : {}),
    limit: 1,
  }
}

/** What "Step back" asks of Claude after interrupting the turn. */
export const STEP_BACK_PROMPT =
  'Stop retrying for a moment. Summarize what you have tried, why it keeps failing, and propose a different approach before running anything else.'

export const basename = (path: string) => path.replace(/\/+$/, '').split('/').pop() || path
