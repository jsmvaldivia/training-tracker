# Scope: project — personal overrides go in CLAUDE.local.md

# Training Tracker

Web app for tracking the trainings and certifications I want to complete —
progress, milestones, and goals. Single user, local development only. Zig
backend (web service) + React frontend (Bun runtime). Keep it simple: prefer
the smallest dependency set that works and don't add infrastructure the app
doesn't need.

## Stack

**Backend** — `api/`
- Zig web service exposing the REST API defined in `api/openapi.yaml`
- JSON file storage (`api/data.json`) — single file, backend-private
- Migrate to SQLite once the domain model stabilizes

**Frontend** — `web/`
- React (Bun runtime, built-in JSX transform)
- API client codegen'd from `api/openapi.yaml` (typed fetch wrappers)
- Never touches `data.json` directly — only talks to the backend via HTTP

**Contract**: `api/openapi.yaml` is the source of truth; backend owns it,
frontend generates types from it. There are no external API consumers.

## MVP scope

Ship these entities first (defer the rest):
- **Pursuit** — name, type (training|certification), target_date, status, started_at, completed_at
- **Milestone** — name, date, pending|achieved, belongs to one pursuit
- **Status** — planned → in_progress → completed (explicit lifecycle)

**Deferred to later**: Plans (cross-pursuit strategy), Tags (filtering), Resources (learning material), Renewal (expiring cert follow-on), Progress gauges (time/achievement %), Timeline view.

See `docs/glossary/` for the full domain model.

## Build & Run

**Backend** (`api/`, Zig 0.16.0 — mind version-specific build API):
```bash
zig build         # compile
zig build run     # start the HTTP server
zig build test    # unit + acceptance tests — the gate
zig fmt api/      # format (CI/agents check with: zig fmt --check api/)
```

**Frontend** (`web/`): not scaffolded yet. Planned: React on Bun
(`bun install`, `bun dev`), types codegen'd from `api/openapi.yaml`.

API linting via Spectral (`api/.spectral.yaml`): `scripts/validate-oas.sh`
lints `api/openapi.yaml` (fails on warnings).

# Commits

- Use Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`, …).
- YOU MUST NOT add `Co-Authored-By: Claude` or any Claude/Anthropic
  attribution line to commit messages.

# Environment

Two environments only: **local** (dev) and **prod** (when deployed). No staging,
no test env, no dev/staging/prod config splits. Keep it binary.

<!-- grill-me:glossary:start -->
## Project glossary
Ground answers about this project in `docs/glossary/index.md`.
Open discrepancies (code vs. intended): `docs/glossary/discrepancies.md`.
<!-- grill-me:glossary:end -->
