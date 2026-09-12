# Training Tracker — agent instructions

Single-user app for tracking trainings and certifications. Local development
only. Zig backend (`api/`) + React frontend on Bun (`web/`). Keep it simple:
smallest dependency set that works, no infrastructure the app doesn't need.

## Setup and verification (Codex and Claude Code)

`mise.toml` pins Zig and Bun. After installing mise, run from the repo root:

```bash
mise trust
mise install
mise exec -- ./scripts/setup.sh
mise exec -- ./scripts/verify.sh
mise exec -- ./scripts/dev.sh
```

Use `mise exec -- <command>` for the commands below when the pinned tools are
not already on PATH. Use it only for commands that need Zig or Bun; run `git`,
`gh`, `grep`, `ls`, and other system tools without it, so command-rewriting
hooks can see the tool name. Setup installs locked dependencies and Chromium;
verify runs OpenAPI lint, Zig formatting and the full backend suite, frontend
unit tests, the mocked E2E suite, and the live full-stack E2E suite. Stop the
dev server first: verification needs port 3000 and always starts a fresh
frontend; the live suite takes 8081 and 3100. Neither command modifies
`api/data.json`.
See `docs/setup.md` for Linux prerequisites and machine migration.

## Architecture decisions (settled — don't re-litigate)

- `api/openapi.yaml` is the contract. Change the spec first, then implement.
  Lint it with `scripts/validate-oas.sh` (Spectral, fails on warnings).
  There are no external API consumers, so no versioning or backward-compat work.
- Storage is one JSON file, `api/data.json`, backend-private and gitignored.
  `scripts/dev.sh` seeds it from the tracked `api/data.seed.json` on first run.
  Do not edit `data.json` from the frontend or from tests.
- SQLite migration is deferred until the domain model stabilizes. Do not add it.
- The Bun server (`web/server.ts`) proxies `/api/*` to the backend on :8080.
  The backend sets no CORS headers; the browser must stay same-origin.
- `web/src/api.ts` is a hand-written client that mirrors `openapi.yaml`.
  When the spec changes, update it by hand — there is no codegen step.
- The web app loads the whole pursuit list on start, walking the API's pages
  (`limit=100`, `web/src/pagination.ts`), and filters by type in memory. No
  server-side filter or pagination controls in the UI: one user has tens of
  pursuits, and the header counts and the timeline need the full set anyway.
  `type`, `limit`, and `offset` stay in the contract for scripts and tests
  (issue #24).
- Two environments only: local and prod. No staging, no per-env config splits.
- Domain model: `docs/glossary/index.md` is the reference; log code-vs-intent
  conflicts in `docs/glossary/discrepancies.md`.

## Backend (`api/`, Zig 0.16.0)

Zig 0.16 build APIs differ from older releases — check `api/build.zig` before
writing build code. Run from `api/`:

```bash
zig build test:unit -j1 # fast, socket-free unit + acceptance tests — the dev loop
zig build test:http -j1 # HTTP integration tests (real server on a thread)
zig build test -j1      # full gate — must pass before every commit
zig build test -j1 -Dtest-filter="milestone"   # subset by test name
zig fmt --check .      # formatting gate
```

`scripts/contract-test.sh` (from the repo root, needs `uv`) runs Schemathesis
against a ReleaseSafe build on a scratch store: the CI `contract` job. Run it
after any change to `openapi.yaml` or the handlers.

`scripts/bench.sh` prints an API performance snapshot (needs `oha`);
`scripts/perf-snapshot.sh` is the gate's `perf` step and fails on a >25 %
regression against `perf-snapshots.jsonl` — commit its new line with your
change. Never benchmark a Debug build.

Gotcha: test binaries include imported module tests and share hardcoded `/tmp`
data paths. Use `-j1` to serialize binaries within a build. Never run the same
file's tests in two processes at once.
Serialize Zig test commands across all agents and worktrees on the same machine.
Before parallel resource implementation, assign a single owner for each shared
file (including routing, storage, and build scaffolding); hand off shared edits
and test execution through the coordinating agent.

## Frontend (`web/`, React 19 + Tailwind 4 on Bun)

```bash
bun dev            # :3000, proxies /api -> :8080
bun test:unit      # bun test src
bun test:e2e       # Playwright, headless; starts `bun dev` itself
bun test:e2e:ui    # interactive debugging
bun test:e2e:live  # full stack: real API on a scratch store (scripts/e2e-live.sh)
```

- Tailwind compiles in-process via `bun-plugin-tailwind` (`web/bunfig.toml`).
  Edit `src/index.css`; the theme lives in its `@theme` block. No CLI, no
  generated CSS file.
- E2E specs live in `web/e2e/*.spec.ts` and mock the API with route
  interception — they do not need the Zig server running.
- Live specs live in `web/e2e-live/*.spec.ts` and use no mocks. Run them only
  through `bun test:e2e:live` (or `scripts/e2e-live.sh`), which builds the API,
  starts it on :8081 with a scratch copy of the seed, starts the web server on
  :3100, and removes both on exit. Keep them few: lifecycle, persistence, and
  rollback flows; filters, layout, and accessibility stay in the mocked suite.
- The `SessionStart` hook in `.claude/settings.json` calls shared setup in
  Claude remote sessions only. Pinned tools must already be on PATH. Local
  sessions use the explicit setup command above; there is no automatic install.

## Full stack

`./scripts/dev.sh` starts both servers and stops both on Ctrl-C.

## Workflow agents

`.claude/agents/` holds six subagents. `/resolve-issue N`
(`.claude/skills/resolve-issue/SKILL.md`, then
`.claude/workflows/build-issue.js`) chains them: `issue-triager` (read-only
brief with one verdict), `oas-designer` (edits the spec with the user),
`test-author` (red outer tests), `resource-implementer` (one backend resource,
TDD), `web-implementer` (the frontend half), `evaluator` (runs the gate,
returns PASS or FAIL). Each agent file carries only its own role. These rules
apply to all of them and are not repeated there:

- No commits, pushes, or PRs; the main session ships.
- `api/openapi.yaml` is read-only after triage. A change goes through
  `oas-designer` with the user, then triage runs again.
- No `.skip`, `.only`, disabled, weakened, or deleted tests to go green. A
  test believed wrong is reported with the line and the reason.
- `api/data.json` is never read or written by tests or agents.
- Test runs are serial (the Backend gotcha above). `build-issue.js` runs the
  implementers one after another, and `web-implementer` never runs beside
  `resource-implementer`: Playwright holds 3000 and 3100.
- The global `pre-push-checker` agent is for other stacks; `evaluator`
  replaces it here.
- Agent files load at session start; restart the session after editing one.

## Commits

- Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`).
- Never add `Co-Authored-By` or any Claude/Anthropic attribution line.
- `scripts/gate.sh` runs every check in order and is the gate before a
  commit; `GATE_SKIP="e2e perf"` names steps to skip. The live suite is
  mandatory for anything that touches `openapi.yaml`, `web/src/api.ts`, or
  `web/server.ts`.
