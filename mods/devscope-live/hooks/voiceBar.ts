import type { VoiceProgress } from '../types'

/** Cells in the bar; each holds six braille dots, so 24 cells are 144 steps. */
export const BAR_CELLS = 24
/** 6-dot braille by how many dots are lit, left column first: ⠀ ⠁ ⠃ ⠇ ⠏ ⠟ ⠿ */
export const LEVELS = ['⠀', '⠁', '⠃', '⠇', '⠏', '⠟', '⠿'] as const
/** The unlit track: the middle row of dots. */
export const TRACK = '⠒'
export const TRACK_COLOR = '#4b5563'
/** Violet to pink to amber, left to right. */
const STOPS: [number, number, number][] = [
  [0x7c, 0x3a, 0xed],
  [0xdb, 0x27, 0x77],
  [0xf5, 0x9e, 0x0b],
]
/** The sweep shown while there is nothing to measure yet. */
const COMET = [1, 3, 6, 6, 3, 1]

export type Cell = { char: string; color: string }

/** The progress file's contents, or undefined for anything malformed. */
export function parseProgress(text: string): VoiceProgress | undefined {
  try {
    const p = JSON.parse(text) as Partial<VoiceProgress>
    const num = (v: unknown) => typeof v === 'number' && Number.isFinite(v) && v >= 0
    if (p.kind !== 'explain' && p.kind !== 'reply') return undefined
    if (p.phase !== 'summarizing' && p.phase !== 'voicing' && p.phase !== 'speaking') return undefined
    if (!num(p.piece) || !num(p.pieces) || !num(p.pieceMs) || !num(p.at)) return undefined
    if (!Number.isInteger(p.pid) || (p.pid as number) <= 1) return undefined
    return {
      kind: p.kind,
      project: typeof p.project === 'string' ? p.project.slice(0, 60) : '',
      phase: p.phase,
      piece: p.piece as number,
      pieces: p.pieces as number,
      pieceMs: p.pieceMs as number,
      at: p.at as number,
      pid: p.pid as number,
      sessionId: typeof p.sessionId === 'string' ? p.sessionId.slice(0, 200) : '',
    }
  } catch {
    return undefined
  }
}

/**
 * A speaker killed without cleaning up leaves its file behind: past the
 * piece's end (or 30 s into a phase with no known length) plus a margin, the
 * file is taken as dead.
 */
export function isStale(p: VoiceProgress, now: number): boolean {
  const expected = p.phase === 'speaking' && p.pieceMs > 0 ? p.pieceMs : 30_000
  return now > p.at + expected + 15_000 || now < p.at - 60_000
}

/** 0..1 while speaking; undefined while the audio is still being made. */
export function fraction(p: VoiceProgress, now: number): number | undefined {
  if (p.phase !== 'speaking' || p.pieces < 1) return undefined
  const within = p.pieceMs > 0 ? Math.min(1, Math.max(0, (now - p.at) / p.pieceMs)) : 0.5
  return Math.min(1, (Math.min(p.piece, p.pieces - 1) + within) / p.pieces)
}

function gradient(t: number): string {
  const x = Math.min(1, Math.max(0, t)) * (STOPS.length - 1)
  const i = Math.min(STOPS.length - 2, Math.floor(x))
  const f = x - i
  const [a, b] = [STOPS[i], STOPS[i + 1]]
  return `#${a.map((v, k) => Math.round(v + (b[k] - v) * f).toString(16).padStart(2, '0')).join('')}`
}

/**
 * The bar's cells: filled to `progress` (0..1), or with `progress` undefined a
 * comet sweeping across, moved on by `frame`. Lit cells take the gradient's
 * color at their position; the rest show the dim track.
 */
export function barCells(progress: number | undefined, frame: number, width = BAR_CELLS): Cell[] {
  const lit = new Array<number>(width).fill(0)
  if (progress === undefined) {
    const head = (frame % (width + COMET.length)) - COMET.length
    COMET.forEach((level, k) => {
      if (head + k >= 0 && head + k < width) lit[head + k] = level
    })
  } else {
    let steps = Math.round(Math.min(1, Math.max(0, progress)) * width * 6)
    for (let i = 0; i < width && steps > 0; i++, steps -= 6) lit[i] = Math.min(6, steps)
  }
  return lit.map((level, i) =>
    level === 0 ? { char: TRACK, color: TRACK_COLOR } : { char: LEVELS[level], color: gradient(i / Math.max(1, width - 1)) },
  )
}

/** Runs of cells that share a color, so a drawing needs fewer elements. */
export function runs(cells: Cell[]): Cell[] {
  const out: Cell[] = []
  for (const c of cells) {
    const last = out.at(-1)
    if (last && last.color === c.color) last.char += c.char
    else out.push({ ...c })
  }
  return out
}

/** The words beside the bar. */
export function voiceLabel(p: VoiceProgress): string {
  const what =
    p.phase === 'summarizing' ? 'summarizing the reply' : p.phase === 'voicing' ? 'creating audio' : p.kind === 'explain' ? 'explaining' : 'reading the summary'
  const part = p.phase === 'speaking' && p.pieces > 1 ? ` ${Math.min(p.piece + 1, p.pieces)}/${p.pieces}` : ''
  return `${p.project ? `${p.project} · ` : ''}${what}${part}`
}

/**
 * Whether this window's session is the one speaking. Progress from an older
 * plugin names no session and counts as everyone's, as it always did.
 */
export function isOwnSpeech(p: VoiceProgress, sessionId: string): boolean {
  return p.sessionId === '' || p.sessionId === sessionId
}

/** The dimmed line other windows show while a session speaks. */
export function otherSpeechLabel(p: VoiceProgress): string {
  return `🔊 ${voiceLabel({ ...p, project: p.project || 'Another session' })}`
}
