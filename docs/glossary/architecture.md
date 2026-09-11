# Architecture

Components, agents, and key decisions for Training Tracker. Each agent's
behaviour is specified in its own file under `.claude/agents/`; the entries
here record what it is for, what it depends on, and the decisions behind it.
The rules every agent shares are in `AGENTS.md`, "Workflow agents".

### resource-implementer (agent)
Implements one backend resource as a full vertical slice — HTTP handler →
validation → JSON-file persistence — test-first, after [[oas-designer]] has
finalized the contract.
- Code anchor: `.claude/agents/resource-implementer.md`
- Depends on / used by: consumes `api/openapi.yaml` from [[oas-designer]];
  implements [[pursuit]], [[milestone]], [[status]]; run by [[resolve-issue]].
- Key decision: autonomous and single-resource (unlike the interactive
  oas-designer) so a caller can spawn one cold instance per resource.
Source: jsmvaldivia, 2026-06-17 · asserted

### oas-designer (agent)
Interactive agent that designs the OpenAPI spec one resource at a time with
the user, lints with Spectral, and writes no implementation code — the seam
that [[resource-implementer]] fills.
- Code anchor: `.claude/agents/oas-designer.md`
- Depends on / used by: produces `api/openapi.yaml`; the only writer of the
  spec inside [[resolve-issue]].
Source: `.claude/agents/oas-designer.md` · verified

### issue-triager (agent)
Read-only first step of [[resolve-issue]]: reads one issue, the glossary
(including [discrepancies](discrepancies.md)), the spec, and the code it
names, and returns a brief with one verdict — `READY`, `SPEC_CHANGE`, or
`NEEDS_CONTEXT`. Implementers treat the brief's seams and acceptance
criteria as pre-approved.
- Code anchor: `.claude/agents/issue-triager.md`
Source: jsmvaldivia, 2026-09-05 · verified

### test-author (agent)
Writes the failing outer tests for a brief — Playwright specs and Zig
HTTP/acceptance tests — and proves each is red for the feature's reason.
Unit tests belong to the implementers.
- Code anchor: `.claude/agents/test-author.md`
- Used by: `.claude/workflows/build-issue.js`, phase Tests.
Source: jsmvaldivia, 2026-09-05 · verified

### web-implementer (agent)
Frontend counterpart of [[resource-implementer]]: makes the failing e2e specs
pass in `web/src/**` with a unit-test-first loop and keeps `web/src/api.ts` a
hand-written mirror of the spec.
- Code anchor: `.claude/agents/web-implementer.md`
Source: jsmvaldivia, 2026-09-05 · verified

### evaluator (agent)
Last step before the PR: runs [[gate.sh]], reads `.gate/result.json` and the
diff against `main`, and returns `PASS` or `FAIL` with findings. Fixes
nothing, so a retry round reflects what the implementers actually did.
- Code anchor: `.claude/agents/evaluator.md`
- Enforces the [[coverage gate]].
Source: jsmvaldivia, 2026-09-05 · verified

### resolve-issue (skill + workflow)
Entry point of the issue-resolution workflow: `/resolve-issue N` turns an
issue into a PR with as little human time as possible. A read-only triager
decides whether a human is needed; humans handle the glossary and the
contract; agents handle tests, code, gates, and the verdict.
- Code anchors: `.claude/skills/resolve-issue/SKILL.md` (interactive half:
  board, triage, grilling, spec design, commit, PR) and
  `.claude/workflows/build-issue.js` (autonomous half: tests, implementers
  in series, gate, evaluator, at most three rounds).
- Design decisions (planned 2026-09-05 as issues #35–#45, all shipped):

| # | Area | Decision | Why |
|---|------|----------|-----|
| 1 | Split | Interactive half in the main session (`resolve-issue` skill), autonomous half as a Workflow script (`build-issue`) | Subagents cannot talk to the user. Grilling and spec design need the user; everything after a READY verdict does not. |
| 2 | Test order | Test-author writes outer acceptance tests only; implementers write unit tests inside red-green | Matches the outside-in loop `resource-implementer` already uses and avoids the horizontal-slice anti-pattern in the `tdd` skill. |
| 3 | Seams | The triage brief lists the seams; implementers treat them as pre-approved | The `tdd` skill requires user confirmation of seams. In an autonomous run the brief is that confirmation. |
| 4 | Spec | Read-only for every agent after triage; changes happen only via `oas-designer` in the interactive half, then re-triage | AGENTS.md: change the spec first, then implement. One entry point into the workflow. |
| 5 | Checks | Deterministic checks live in `scripts/gate.sh`, which writes JSON; the evaluator reads it | Agents judge, scripts execute. The same script backs CI so gates cannot drift. |
| 6 | Evaluator | Read-only, returns PASS or FAIL with findings; retry capped at three rounds | An evaluator that fixes things hides failures. A cap stops runaway loops. |
| 7 | Coverage | Bun line-coverage threshold for `web/src`; diff rule for `api/src` now, kcov on Linux CI later | Zig has no coverage tool and kcov does not work well on macOS. |
| 8 | Board | In Progress via `gh project item-edit` in the skill; Done via the built-in "item closed" project workflow plus `Closes #N` | Zero agent code for the merge side. |
| 9 | Concurrency | Backend and frontend implementers run in series; one worktree per issue | Zig tests share hardcoded `/tmp` data paths; Playwright takes port 3000. |

Source: jsmvaldivia, 2026-09-05 · verified

### Project board
GitHub project 3 "Training Tracker" tracks every issue with a single-select
`Status` field: Todo, In Progress, Done.
- Ids: project `PVT_kwHOAth7oc4BiY_Z`; Status field
  `PVTSSF_lAHOAth7oc4BiY_ZzhhROiM`; options Todo `f75ad846`, In Progress
  `47fc9ee4`, Done `98236657`. Item ids come from
  `gh project item-list 3 --owner jsmvaldivia --format json`.
- In Progress: set by the [[resolve-issue]] skill with `gh project item-edit`
  when work on an issue starts.
- Done: no agent code. The project's built-in workflow "Item closed → set
  Status: Done" is enabled in the project settings on github.com (a one-time
  manual step); the PR body's `Closes #N` closes the issue on merge, which
  moves the card.
Source: jsmvaldivia, 2026-09-05 · asserted (the built-in workflow toggle is set on github.com, not in this repo)

### gate.sh (script)
The local gate: every deterministic check, in order, in one process, with a
machine-readable result. Agents judge; this script executes.
- Code anchor: `scripts/gate.sh` (its header lists the steps).
- Output: `.gate/result.json` (gitignored) — `overall`, commit, branch, and one
  entry per step with `status` (`passed` | `failed` | `skipped`), exit code,
  duration, reason, and the output tail. A step that did not run is `skipped`,
  never `passed`. Per-step logs sit next to it.
- `GATE_SKIP="e2e perf"` skips named steps; they are recorded as skipped.
- Consumed by [[evaluator]] and by the CI `backend` and `frontend` workflows,
  which run it with the other stack's steps in `GATE_SKIP`, so local and CI
  gates cannot drift.
Source: jsmvaldivia, 2026-09-04 · verified

### coverage gate
How "no production code without a test" is enforced, per stack.
- **web/** — Bun line + function coverage ≥ 80% of the files unit tests load,
  enforced by `coverageThreshold` in `web/bunfig.toml`. Bun does not count
  files no test imports, so this is a floor for reached code, not a census.
- **api/** — Zig has no coverage tool and kcov does not run well on macOS, so
  the rule is structural: every changed production file in `api/src` must have
  a changed or added test that exercises it. [[evaluator]] checks this from the
  diff. Also applied to `web/src` files that only Playwright reaches.
- Later: kcov on a Linux CI runner replaces the structural rule for `api/`.
Source: jsmvaldivia, 2026-09-04 · asserted
