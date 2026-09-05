# Architecture

Components, agents, and key decisions for Training Tracker.

### resource-implementer (agent)
A Claude subagent that implements one backend resource as a **full vertical
slice** — HTTP handler → request/response (de)serialization → domain
validation → JSON-file persistence — using TDD, after [[oas-designer]] has
finalized the contract.
- Code anchor: `.claude/agents/resource-implementer.md`
- Scope: one resource per instance. Top boundary = HTTP handler wired to the
  OAS path; bottom boundary = JSON-file repository against `api/data.json`.
  Does **not** touch `web/` frontend, SQLite, or auth.
- Handoff: invoked with a **named resource** (e.g. "implement Pursuit"). Cold
  start — grounds itself by reading `api/openapi.yaml` for that resource's
  paths + schemas, treating the spec as source of truth. If the resource is
  absent from the spec, it stops and reports.
- Fan-out: the **parent/orchestrator** spawns one instance per resource
  (parallel-safe — each writes different files). The agent itself does not
  spawn children, so it does not need the Agent tool.
- TDD shape: acceptance test up front (failing, defines "done"), then
  inside-out unit TDD per layer (persistence → domain → handler); the
  acceptance test going green = slice complete.
- Definition of done (machine-checkable gate): acceptance test green +
  `zig build test` all pass + `zig fmt` clean + zero skipped/disabled tests.
- Git: does **not** commit — leaves a clean working tree for human review
  (avoids parallel agents racing on git). Reports files changed + test summary.
- Spec authority: `api/openapi.yaml` is **immutable** to this agent. On a spec
  gap/contradiction it halts the slice and reports the precise gap so
  [[oas-designer]] (single owner) fixes the contract first.
- Tools: `Read, Write, Edit, Bash, Glob, Grep`. Model: `opus`.
- Depends on / used by: consumes the output of [[oas-designer]]; implements
  [[pursuit]], [[milestone]], [[status]] (MVP resources).
- Key decision: kept autonomous and single-resource (vs. interactive like
  oas-designer) precisely so the orchestrator can fan out parallel cold
  subagents, one per resource.
Source: jsmvaldivia, 2026-06-17 · asserted

### oas-designer (agent)
Interactive agent that designs the OpenAPI spec one resource at a time, lints
with Spectral, and explicitly writes **no implementation code** — the seam that
[[resource-implementer]] fills.
- Code anchor: `.claude/agents/oas-designer.md`
- Depends on / used by: produces `api/openapi.yaml`, consumed by
  [[resource-implementer]].
Source: `.claude/agents/oas-designer.md` · verified

### issue-triager (agent)
Read-only first step of the issue-resolution workflow: reads one issue, the
glossary (including [discrepancies](discrepancies.md)), the spec, and the code
it names, and returns a brief with fixed sections and one verdict.
- Code anchor: `.claude/agents/issue-triager.md`
- Verdicts: `READY` (spec and glossary cover it — code-vs-spec divergences
  included), `SPEC_CHANGE` (names the resource and the missing operation,
  field, or status code), `NEEDS_CONTEXT` (typed gaps: domain, architecture,
  spec; a question in the issue is always a gap).
- Brief sections: issue, goal, glossary terms, layers (with backend resource
  names), seams (test files), acceptance criteria, verdict detail. Implementers
  treat the seams and criteria as pre-approved.
- Tools: Read, Grep, Glob, Bash for `gh`/`git` reads. Writes nothing.
- Used by: [[resolve-issue]] (skill).
Source: jsmvaldivia, 2026-09-05 · verified

### test-author (agent)
Writes the failing outer tests for a brief — Playwright specs from the
acceptance criteria, Zig HTTP/acceptance tests from the spec — and proves
each is red for the feature's reason. Unit tests belong to the implementers.
- Code anchor: `.claude/agents/test-author.md`
- May write: `web/e2e/*.spec.ts`, `web/e2e/support/*`, `web/e2e-live/*.spec.ts`,
  `api/src/http_test*.zig`, `api/src/acceptance_*.zig`, the test lists in
  `api/build.zig`. Never production code, never `api/openapi.yaml`.
- Stops and reports: a test that passes before implementation, a criterion
  it cannot test.
- Used by: `.claude/workflows/build-issue.js`, phase Tests.
Source: jsmvaldivia, 2026-09-05 · verified

### web-implementer (agent)
Frontend counterpart of [[resource-implementer]]: makes the failing e2e specs
pass in `web/src/**` with a unit-test-first loop, keeps `web/src/api.ts` a
hand-written mirror of the spec, and addresses evaluator findings on a retry.
- Code anchor: `.claude/agents/web-implementer.md`
- Reads only: `web/e2e/**`, `web/e2e-live/**`, `api/**`, `api/openapi.yaml`.
  A spec it believes wrong is reported, not edited.
- Gates: `bun test:unit` (coverage threshold), `bun test:e2e`, and
  `bun test:e2e:live` when the flow crosses the API. Never in parallel with
  resource-implementer (ports 3000/3100, shared `/tmp` Zig paths).
Source: jsmvaldivia, 2026-09-05 · verified

### evaluator (agent)
Last step before the PR: runs [[gate.sh]], reads `.gate/result.json` and the
diff against `main`, and returns `PASS` or `FAIL` with findings. Fixes
nothing, so a retry round reflects what the implementers actually did.
- Code anchor: `.claude/agents/evaluator.md`
- Rules: every gate step passed or skipped for a known reason; every
  acceptance criterion maps to a test; every changed production file has a
  test that exercises it ([[coverage gate]]); `api.ts` mirrors a changed
  spec; no test skipped, disabled, or weakened; no spec edit after triage;
  `api/data.json` untouched.
- Finding shape: file, line, what is wrong, what a fix must satisfy.
- Tools: Read, Grep, Glob, Bash for `scripts/gate.sh` and `git diff` only.
Source: jsmvaldivia, 2026-09-05 · verified

### resolve-issue (skill + workflow)
Entry point of the issue-resolution workflow: `/resolve-issue N`.
- Code anchors: `.claude/skills/resolve-issue/SKILL.md` (interactive half),
  `.claude/workflows/build-issue.js` (autonomous half, workflow `build-issue`).
- Interactive half, main session: board card to In Progress and
  `needs-triage` removed; [[issue-triager]]; `NEEDS_CONTEXT` → `grill-me` →
  re-triage; `SPEC_CHANGE` → `grill-me` if a term is missing → [[oas-designer]]
  → `scripts/validate-oas.sh` → re-triage (spec frozen after lint); `READY`
  → worktree → Workflow.
- Autonomous half, Workflow script with `args { issue, brief, resources, web }`:
  [[test-author]]; then per backend resource [[resource-implementer]], then
  [[web-implementer]], strictly in series; then [[evaluator]]. `FAIL` feeds
  the findings back and repeats the implement/evaluate pair, at most three
  rounds. Returns `{ verdict, rounds, findings }`.
- Back in the main session: Conventional Commit, push, `gh pr create` with
  `Closes #N` in the body.
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
- Code anchor: `scripts/gate.sh`
- Steps, stop at first failure: `deps` (`bun install --frozen-lockfile`,
  worktrees start without `node_modules`), `fmt` (`zig fmt --check`), `oas-lint`
  (`scripts/validate-oas.sh`), `zig-test` (`zig build test`), `unit-cov`
  (`bun test src` with the coverage threshold), `e2e` (`bun test:e2e`),
  `perf` (runs `scripts/perf-snapshot.sh` when it exists, else skipped with a
  reason — issue #35).
- Output: `.gate/result.json` (gitignored) — `overall`, commit, branch, and one
  entry per step with `status` (`passed` | `failed` | `skipped`), exit code,
  duration, reason, and the output tail. A step that did not run is `skipped`,
  never `passed`. Per-step logs sit next to it.
- Preconditions: refuses to start when another `zig build test` is running
  (tests share hardcoded `/tmp` data paths) or when port 3000 is held
  (Playwright must start its own server).
- `GATE_SKIP="e2e perf"` skips named steps; they are recorded as skipped.
- Consumed by [[evaluator]] (agent) and, later, by CI (#13, #14) so local and
  CI gates cannot drift.
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
