/** One proposal from `POST /api/live/next-prompts`. */
export type Suggestion = { text: string; project: string }

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

/** Thresholds for team prompt suggestions: few, short, and only when they fit. */
export const SUGGEST = {
  /** Shown text is a few words; anything longer is dropped, whatever the server sent. */
  maxWords: 5,
  maxChars: 60,
  /** After this many suggestions in a row are typed over, stop for a while. */
  ignoreLimit: 3,
  pauseMs: 30 * 60 * 1000,
} as const

const fold = (text: string) => text.toLowerCase().replace(/\s+/g, ' ').trim()

/** Short enough to read at a glance in the prompt box, and on one line. */
export function fitsSuggestion(text: string): boolean {
  const t = text.trim()
  return t !== '' && !t.includes('\n') && t.length <= SUGGEST.maxChars && t.split(/\s+/).length <= SUGGEST.maxWords
}

/**
 * Whether a finished turn is a moment for a suggestion: Claude did some work
 * (a pure chat answer leaves the next step open), and did not end by asking
 * something: then the person's answer is the next prompt, and only they know it.
 */
export function shouldSuggestAfter(turn: { answer: string; toolCalls: number }): boolean {
  if (turn.toolCalls < 1) return false
  const lastLine = turn.answer.trim().split('\n').filter(l => l.trim() !== '').at(-1) ?? ''
  return !/\?\W*$/.test(lastLine.trim())
}

/**
 * The next state after a prompt is sent while a suggestion was showing: taking
 * it resets the count, typing something else counts as ignoring it, and the
 * third ignore in a row pauses suggestions for `SUGGEST.pauseMs`.
 */
export function afterPrompt(
  state: { ignored: number; pausedUntil: number },
  sent: string,
  suggested: string,
  now: number,
): { ignored: number; pausedUntil: number } {
  if (fold(sent) === fold(suggested)) return { ignored: 0, pausedUntil: state.pausedUntil }
  const ignored = state.ignored + 1
  return ignored >= SUGGEST.ignoreLimit ? { ignored: 0, pausedUntil: now + SUGGEST.pauseMs } : { ignored, pausedUntil: state.pausedUntil }
}

/** What "Step back" asks of Claude after interrupting the turn. */
export const STEP_BACK_PROMPT =
  'Stop retrying for a moment. Summarize what you have tried, why it keeps failing, and propose a different approach before running anything else.'

export const basename = (path: string) => path.replace(/\/+$/, '').split('/').pop() || path
