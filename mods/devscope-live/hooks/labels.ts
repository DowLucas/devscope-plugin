export type Label = 'up' | 'partial' | 'down'

/** A reply that says the last turn did not do what was asked. */
const DOWN =
  /^(no\b|nope\b|wrong\b|that'?s (not|wrong)|(it|that|this) (is|isn'?t) (not )?(right|working)|still (fail|broken|not|doesn'?t|error)|((it|that|this) )?(doesn'?t|didn'?t|does not|did not) work|((it|that) )?(still )?(fails|failed|errors|breaks|broke)\b|revert\b|undo (that|this|it)\b)/i
/** A reply that says it did. */
const UP = /^(thanks|thank you|thx|perfect|great|nice|awesome|it works|that works|works\b|lgtm|looks good)/i

/** The label a reply implies for the turn it answers, if it clearly implies one. */
export function implicitLabel(reply: string): Label | undefined {
  const text = reply.trim()
  if (DOWN.test(text)) return 'down'
  if (UP.test(text)) return 'up'
  return undefined
}

/** Ask "did that work?" only after a long or busy turn, at most every 30 minutes. */
export const ASK = { minDurationMs: 120_000, minToolCalls: 15, gapMs: 30 * 60_000 }

export function shouldAsk(
  turn: { durationMs: number; toolCalls: number },
  lastAskAt: number,
  now: number,
): boolean {
  const isBig = turn.durationMs >= ASK.minDurationMs || turn.toolCalls >= ASK.minToolCalls
  return isBig && now - lastAskAt >= ASK.gapMs
}
