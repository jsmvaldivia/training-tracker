# Scope: project
# Commit to git: yes — personal overrides go in CLAUDE.local.md

# Training Tracker

Web app for tracking the trainings and certifications I want to complete —
progress, milestones, and goals. Single user, local development only. Zig
backend (web service) + React frontend (Bun runtime). JSON file storage for MVP,
migrating to SQLite later. Keep it simple: prefer the smallest dependency set
that works and don't add infrastructure the app doesn't need.

## Stack

**Backend** — `api/`
- Zig web service exposing REST API defined in `api/openapi.yaml`
- JSON file storage (`api/data.json`) — single file, backend-private
- Migrate to SQLite once domain model stabilizes

**Frontend** — `web/`
- React (Bun runtime, built-in JSX transform)
- API client codegen'd from `api/openapi.yaml` (typed fetch wrappers)
- Never touches `data.json` directly — only talks to backend via HTTP

**Contract**: `api/openapi.yaml` is the source of truth; backend owns it,
frontend generates types from it.

## MVP scope

Ship these entities first (defer the rest):
- **Pursuit** — name, type (training|certification), target_date, status, started_at, completed_at
- **Milestone** — name, date, pending|achieved, belongs to one pursuit
- **Status** — planned → in_progress → completed (explicit lifecycle)

**Deferred to later**: Plans (cross-pursuit strategy), Tags (filtering), Resources (learning material), Renewal (expiring cert follow-on), Progress gauges (time/achievement %), Timeline view.

See `docs/glossary/` for full domain model.

## Build & Run

**Backend:**
```bash
cd api
zig build
zig build run  # starts HTTP server
```

**Frontend:**
```bash
cd web
bun install
bun dev  # talks to http://localhost:<backend-port>
```

(Adjust once actual build setup exists.)

# Commits

- Use Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`, …).
- YOU MUST NOT add `Co-Authored-By: Claude` or any Claude/Anthropic
  attribution line to commit messages.

# Environment

Two environments only: **local** (dev) and **prod** (when deployed). No staging, no test env, no dev/staging/prod config splits. Keep it binary.

<!-- grill-me:glossary:start -->
## Project glossary
Ground answers about this project in `docs/glossary/index.md`.
Open discrepancies (code vs. intended): `docs/glossary/discrepancies.md`.
<!-- grill-me:glossary:end -->
