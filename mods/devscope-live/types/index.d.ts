/** A friction nudge the backend raised for this session. */
export type StuckNudge = { rule: string; severity: string; message: string }

/** What the band above the prompt shows; one thing at a time. */
export type Band =
  | { kind: 'stuck'; nudge: StuckNudge }
  | { kind: 'label'; turnStartedAt: string }
  | null

/**
 * What the Bash plugin's speaker is doing (~/.cache/devscope/voice/progress.json):
 * `at` is when the phase or piece began (epoch ms), `pieceMs` how long the piece
 * plays (0 when unknown), `pid` the speaker's process group.
 */
export type VoiceProgress = {
  kind: 'explain' | 'reply'
  project: string
  phase: 'summarizing' | 'voicing' | 'speaking'
  piece: number
  pieces: number
  pieceMs: number
  at: number
  pid: number
}

/** The voice bar: the latest progress, and a frame counter that animates it. */
export type VoiceView = { progress: VoiceProgress; frame: number } | null

declare module 'claude-code' {
  interface PluginState {
    'devscope-live': { band: Band; voice: VoiceView }
  }
}
