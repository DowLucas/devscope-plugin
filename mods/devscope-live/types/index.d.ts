/** A friction nudge the backend raised for this session. */
export type StuckNudge = { rule: string; severity: string; message: string }

/** What the band above the prompt shows; one thing at a time. */
export type Band =
  | { kind: 'stuck'; nudge: StuckNudge }
  | { kind: 'label'; turnStartedAt: string }
  | null

declare module 'claude-code' {
  interface PluginState {
    'devscope-live': { band: Band }
  }
}
