export type TeamSkill = {
  id: string
  name: string
  description: string
  triggerPhrases: string[]
  content: string
}

/** A shorter phrase ("test", "fix it") matches far more prompts than it means. */
const MIN_PHRASE_CHARS = 8
const MAX_CONTENT_CHARS = 20_000
export const USE_IT = 'Use it'

const normalize = (text: string) =>
  ` ${text.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim()} `

/** The skill whose longest trigger phrase appears in the prompt as whole words. */
export function matchSkill(prompt: string, skills: readonly TeamSkill[]): TeamSkill | undefined {
  const text = normalize(prompt)
  let best: { skill: TeamSkill; length: number } | undefined
  for (const skill of skills) {
    for (const phrase of skill.triggerPhrases) {
      const needle = normalize(phrase)
      const length = needle.trim().length
      if (length >= MIN_PHRASE_CHARS && length > (best?.length ?? 0) && text.includes(needle)) {
        best = { skill, length }
      }
    }
  }
  return best?.skill
}

/** What the model reads beside the prompt once the person chose the skill. */
export function skillContext(skill: TeamSkill): string {
  return [
    `DevScope: the user chose to apply their team's skill "${skill.name}" to this request. Follow it:`,
    '',
    skill.content.slice(0, MAX_CONTENT_CHARS),
  ].join('\n')
}
