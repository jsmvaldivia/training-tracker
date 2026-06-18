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
