import type { PluginOptions } from 'claude-code'

export type Privacy = 'standard' | 'private' | 'open'

export type Config = {
  url: string
  apiKey: string | undefined
  privacy: Privacy
}

/** The mod's own toggles (plugin.json `userConfig`). */
export type Options = {
  nextPrompts: boolean
  teamSkills: boolean
  stuckBand: boolean
  outcomeLabels: boolean
  commitLinks: boolean
  commitTrailer: boolean
}

export function readOptions(options: PluginOptions): Options {
  const flag = (name: keyof Options, fallback: boolean) =>
    typeof options[name] === 'boolean' ? (options[name] as boolean) : fallback
  return {
    nextPrompts: flag('nextPrompts', true),
    teamSkills: flag('teamSkills', true),
    stuckBand: flag('stuckBand', true),
    outcomeLabels: flag('outcomeLabels', true),
    commitLinks: flag('commitLinks', true),
    commitTrailer: flag('commitTrailer', false),
  }
}

/**
 * The Bash plugin's settings with its precedence (scripts/_helpers.sh): the
 * environment, then the config file, then defaults.
 */
export function resolveConfig(
  env: { url?: string; apiKey?: string; privacy?: string },
  file: Record<string, string>,
): Config {
  const url = env.url || file.DEVSCOPE_URL || 'http://localhost:6767'
  const privacy = env.privacy || file.DEVSCOPE_PRIVACY
  return {
    url: url.replace(/\/+$/, ''),
    apiKey: env.apiKey || file.DEVSCOPE_API_KEY || undefined,
    privacy: privacy === 'private' || privacy === 'open' ? privacy : 'standard',
  }
}

/** `KEY=value` lines; `#` comments and blank lines skipped, one pair of quotes stripped. */
export function parseConfig(text: string): Record<string, string> {
  const values: Record<string, string> = {}
  for (const line of text.split('\n')) {
    if (line.startsWith('#')) continue
    const at = line.indexOf('=')
    if (at < 0) continue
    const key = line.slice(0, at).replace(/\s/g, '')
    const value = line.slice(at + 1).trim().replace(/^(["'])(.*)\1$/, '$2')
    if (key) values[key] = value
  }
  return values
}
