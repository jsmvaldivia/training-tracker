// build-issue: the autonomous half of the resolve-issue skill (issue #44).
// Outer tests first,
// then the implementers in series, then a gated verdict — at most three
// rounds. The interactive half (triage, grilling, spec design, board, PR)
// lives in .claude/skills/resolve-issue/SKILL.md and calls this with
//   args: { issue, brief, resources, web }
//     issue      number of the GitHub issue
//     brief      the READY triage brief, verbatim
//     resources  backend resource names from the brief's Layers section ([] for none)
//     web        true when the brief's Layers section names web
export const meta = {
  name: 'build-issue',
  description: 'Write failing outer tests, implement backend then frontend in series, gate, and evaluate — up to three rounds',
  phases: [
    { title: 'Tests', detail: 'test-author writes red acceptance tests from the brief' },
    { title: 'Implement', detail: 'resource-implementer per backend resource, then web-implementer, one at a time' },
    { title: 'Evaluate', detail: 'evaluator runs scripts/gate.sh and judges the diff' },
  ],
}

const MAX_ROUNDS = 3
const { issue, brief, resources = [], web = false } = args

const VERDICT = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['PASS', 'FAIL'] },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'string' },
          problem: { type: 'string' },
          fix_must: { type: 'string' },
        },
        required: ['file', 'problem', 'fix_must'],
      },
    },
  },
  required: ['verdict', 'findings'],
}

const briefBlock = `Issue #${issue}. Triage brief (approved — its seams and acceptance criteria are final):\n\n${brief}`

function feedbackBlock(findings) {
  if (!findings.length) return ''
  const lines = findings.map((f, i) => `${i + 1}. ${f.file}:${f.line ?? '-'} — ${f.problem}\n   A fix must satisfy: ${f.fix_must}`)
  return `\n\nEvaluator findings from the previous round — address every one and say how:\n${lines.join('\n')}`
}

phase('Tests')
const tests = await agent(
  `${briefBlock}\n\nWrite the failing outer acceptance tests for this brief and prove each one is red for the right reason. Report the test names with their failure reasons.`,
  { agentType: 'test-author', label: 'test-author', phase: 'Tests' }
)
log(`tests written: ${tests ? String(tests).split('\n')[0] : 'no report'}`)

let findings = []
for (let round = 1; round <= MAX_ROUNDS; round++) {
  phase('Implement')
  // Strictly serial: Zig tests share /tmp data paths and Playwright takes ports.
  for (const resource of resources) {
    await agent(
      `${briefBlock}\n\nImplement the ${resource} resource for this brief. The acceptance and HTTP tests already written for the issue are read-only.${feedbackBlock(findings)}`,
      { agentType: 'resource-implementer', label: `resource-implementer:${resource}`, phase: 'Implement' }
    )
  }
  if (web) {
    await agent(
      `${briefBlock}\n\nImplement the frontend half of this brief in web/src until the failing e2e specs pass. The specs are read-only.${feedbackBlock(findings)}`,
      { agentType: 'web-implementer', label: 'web-implementer', phase: 'Implement' }
    )
  }

  phase('Evaluate')
  const result = await agent(
    `${briefBlock}\n\nRound ${round} of ${MAX_ROUNDS}. Run scripts/gate.sh, read .gate/result.json and the diff against main, apply every rule, and return the verdict with findings.`,
    { agentType: 'evaluator', label: `evaluator:round-${round}`, phase: 'Evaluate', schema: VERDICT }
  )
  if (!result) {
    log(`round ${round}: evaluator returned nothing; stopping`)
    return { verdict: 'FAIL', rounds: round, findings: [{ file: '-', problem: 'evaluator returned no verdict', fix_must: 'rerun the workflow' }] }
  }
  if (result.verdict === 'PASS') {
    log(`round ${round}: PASS`)
    return { verdict: 'PASS', rounds: round, findings: [] }
  }
  findings = result.findings
  log(`round ${round}: FAIL with ${findings.length} finding(s)`)
}

return { verdict: 'FAIL', rounds: MAX_ROUNDS, findings }
