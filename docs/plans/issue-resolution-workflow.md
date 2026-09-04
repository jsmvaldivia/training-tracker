# Plan: Issue-resolution workflow

Turn a GitHub issue into a merged PR with as little human time as possible.
A read-only triager decides whether a human is needed. Humans handle the
glossary and the API contract. Agents handle tests, code, gates, and the
verdict. The board follows along.

Tracking issues: #37–#45 (new), plus #35 (perf baseline) as a prerequisite.

## Design decisions

| # | Area | Decision | Why |
|---|------|----------|-----|
| 1 | Split | Interactive half in the main session, autonomous half as a Workflow script | Subagents cannot talk to the user. Grilling and spec design need the user; everything after a READY verdict does not. |
| 2 | Test order | Test-author writes outer acceptance tests only; implementers write unit tests inside red-green | Matches the outside-in loop `resource-implementer` already uses and avoids the horizontal-slice anti-pattern in the `tdd` skill. |
| 3 | Seams | The triage brief lists the seams; implementers treat them as pre-approved | The `tdd` skill requires user confirmation of seams. In an autonomous run the brief is that confirmation. |
| 4 | Spec | Read-only for every agent after triage; changes happen only via `oas-designer` in the interactive half, then re-triage | AGENTS.md: change the spec first, then implement. One entry point into the workflow. |
| 5 | Checks | Deterministic checks live in `scripts/gate.sh`, which writes JSON; the evaluator reads it | Agents judge, scripts execute. The same script backs CI later so gates cannot drift. |
| 6 | Evaluator | Read-only, returns PASS or FAIL with findings; retry capped at three rounds | An evaluator that fixes things hides failures. A cap stops runaway loops. |
| 7 | Coverage | Bun line-coverage threshold for `web/src`; diff rule for `api/src` now, kcov on Linux CI later | Zig has no coverage tool and kcov does not work well on macOS. |
| 8 | Board | In Progress via `gh project item-edit` in the skill; Done via the built-in "item closed" project workflow plus `Closes #N` | Zero agent code for the merge side. |
| 9 | Concurrency | Backend and frontend implementers run in series; one worktree per issue | Zig tests share hardcoded `/tmp` data paths; Playwright takes port 3000. |

## Verified ground truth

- Existing agents: `oas-designer` (interactive, writes the spec, lints with
  Spectral) and `resource-implementer` (backend only, one resource, TDD, no
  commit). Both in `.claude/agents/`.
- Existing skills used as-is: `tdd`, `grill-me` (with `grilling` and
  `domain-modeling`), `perf-audit`, `perf-run`, `workflow-authoring`,
  `writing-for-agents`, `agent-roster`.
- No coverage tooling is configured. `kcov` is not installed. Bun 1.3 supports
  `bun test --coverage` and `coverageThreshold` in `bunfig.toml`.
- No perf instrumentation and no `perf-snapshots.jsonl`. Issue #35 creates them.
- Project 3 "Training Tracker": Status field `PVTSSF_lAHOAth7oc4BiY_ZzhhROiM`
  with options Todo `f75ad846`, In Progress `47fc9ee4`, Done `98236657`.
  Project id `PVT_kwHOAth7oc4BiY_Z`.
- The global `pre-push-checker` agent looks for Java debug statements. Do not
  use it here; the evaluator replaces it.
- Open spec-divergence issues (#30–#32) are the "no spec change" path: code
  moves toward the spec.

## Flow

Interactive half (main session, `/resolve-issue N`):

1. Read the issue. Board card to In Progress. Remove `needs-triage`.
2. `issue-triager` returns a brief with one verdict.
3. NEEDS_CONTEXT → `grill-me` on the gap topic → re-run triage.
4. SPEC_CHANGE → `grill-me` if a term is missing → `oas-designer` for the named
   resource → `scripts/validate-oas.sh` → re-run triage. Spec frozen after lint.
5. READY → worktree for the issue → hand the brief to the Workflow.

Autonomous half (Workflow script):

1. `test-author` writes failing e2e and API acceptance tests.
2. `resource-implementer` per backend resource, then `web-implementer`.
3. `scripts/gate.sh` → `.gate/result.json`.
4. `evaluator` → PASS, or FAIL with findings → back to step 2, max three rounds.
5. PASS → return to the main session → commit → `gh pr create` with `Closes #N`.

## Task graph

### Wave 0 — prerequisites (parallel, disjoint files)

- **#35 — perf baseline.** `perf-audit` then `perf-run`; creates
  `perf-snapshots.jsonl` and the regression check. Owns `scripts/perf*`.
- **#37 — coverage gate.** `web/bunfig.toml` threshold; Zig strategy recorded
  in `docs/glossary/architecture.md`.
- **#38 — `scripts/gate.sh`.** Six steps, JSON summary, perf step skipped with
  a reason until #35 lands. Owns `scripts/gate.sh`, `.gitignore`.
- **#45 — board.** Enable the "item closed → Done" project workflow on
  github.com (manual, user). Record ids in the glossary.

### Wave 1 — agents (parallel, one file each)

- **#39 — `issue-triager`.** Read-only. Three verdicts. Reads
  `discrepancies.md` so known conflicts land in the brief.
- **#40 — `test-author`.** Acceptance tests only; proves RED.
- **#41 — `web-implementer`.** Mirror of `resource-implementer` for `web/`;
  keeps `api.ts` matching the spec.
- **#42 — `evaluator`.** Read-only; reads `.gate/result.json` and the diff.
  Depends on the JSON shape from #38, so agree the shape first.
- **#43 — `resource-implementer` adaptation.** Brief input, feedback input,
  acceptance tests read-only.

Write all five with the `writing-for-agents` skill. Optionally run
`agent-roster` first and keep its `.claude/agents/DESIGN.md`.

### Wave 2 — orchestrator

- **#44 — `resolve-issue` skill and Workflow script.** Depends on every
  Wave 1 issue and on #38. Interactive half in the skill, autonomous half in
  the script, retry loop capped at three.

### Wave 3 — dry runs, one per path

1. **No spec change:** #32 (clamped limit/offset). Expect READY on the first
   triage and a PR after one or two rounds.
2. **Needs context:** #29 (milestone overdue). Expect NEEDS_CONTEXT if the
   glossary lacks the milestone rule, then READY after grilling.
3. **Spec change:** #27 (Renewal, `leads_to`). Expect SPEC_CHANGE, an
   `oas-designer` session, lint, then READY.

Each dry run that fails becomes a fix to the agent or script, not a manual
patch to the branch.

### Wave 4 — CI reuse

- Point #13 and #14 at `scripts/gate.sh` so CI and local gates are one thing.
- Revisit #37: replace the Zig diff rule with kcov on a Linux runner.

## Agent constraints (summary)

| Agent | Tools | May write | Stops and reports when |
|---|---|---|---|
| `issue-triager` | Read, Grep, Glob, Bash (`gh`/`git` read) | nothing | term undefined, spec gap |
| `test-author` | Read, Write, Edit, Bash, Glob, Grep | `web/e2e/*.spec.ts`, `api/src/http_test*.zig`, `api/src/acceptance_*.zig`, test lists in `api/build.zig` | a test passes before implementation, brief lacks a criterion |
| `resource-implementer` | as today | `api/src/**` minus acceptance and HTTP test files | spec ambiguous, acceptance test wrong |
| `web-implementer` | same | `web/src/**` | e2e spec wrong, `api.ts` drifted |
| `evaluator` | Read, Grep, Glob, Bash (`gate.sh`, `git diff`) | nothing | never; returns a verdict |

Rules for all: no commits, no spec edits after triage, no edits to
`api/data.json`, never skip or disable a test.

## Done when

- `/resolve-issue 32` produces a green PR with `Closes #32` and the card is
  In Progress during the run.
- Merging that PR moves the card to Done without agent involvement.
- `scripts/gate.sh` runs the same steps locally and in CI.
