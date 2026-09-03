# Training Tracker — agent instructions

Single-user app for tracking trainings and certifications. Local development
only. Zig backend (`api/`) + React frontend on Bun (`web/`). Keep it simple:
smallest dependency set that works, no infrastructure the app doesn't need.

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
zig build test:unit    # fast, socket-free unit + acceptance tests — the dev loop
zig build test:http    # HTTP integration tests (real server on a thread)
zig build test         # full gate — must pass before every commit
zig build test -Dtest-filter="milestone"   # subset by test name
zig fmt --check .      # formatting gate
```

Gotcha: every test file is its own binary and they share hardcoded `/tmp`
data paths. Never run the same file's tests in two processes at once.

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
- The `SessionStart` hook in `.claude/settings.json` installs Playwright
  Chromium in cloud sessions only; local machines manage their own browsers.

## Full stack

`./scripts/dev.sh` starts both servers and stops both on Ctrl-C.

## Commits

- Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`).
- Never add `Co-Authored-By` or any Claude/Anthropic attribution line.
- Run `zig build test` and `bun test:e2e` before committing changes in their area.
