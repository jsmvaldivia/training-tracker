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
not already on PATH. Setup installs locked dependencies and Chromium; verify
runs OpenAPI lint, Zig formatting and the full backend suite, frontend unit
tests, and E2E tests. Stop the dev server first: verification needs port 3000
and always starts a fresh frontend. Neither command modifies `api/data.json`.
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
```

- Tailwind compiles in-process via `bun-plugin-tailwind` (`web/bunfig.toml`).
  Edit `src/index.css`; the theme lives in its `@theme` block. No CLI, no
  generated CSS file.
- E2E specs live in `web/e2e/*.spec.ts` and mock the API with route
  interception — they do not need the Zig server running.
- The `SessionStart` hook in `.claude/settings.json` calls shared setup in
  Claude remote sessions only. Pinned tools must already be on PATH. Local
  sessions use the explicit setup command above; there is no automatic install.

## Full stack

`./scripts/dev.sh` starts both servers and stops both on Ctrl-C.

## Commits

- Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`).
- Never add `Co-Authored-By` or any Claude/Anthropic attribution line.
- Run `zig build test -j1` and `bun test:e2e` before committing changes in their area.
