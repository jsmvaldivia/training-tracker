# Training Tracker

A small web app for tracking the trainings and certifications I want to
complete — their progress, milestones, and goals. Single user, local
development only. Built to stay simple: the smallest dependency set that works,
no infrastructure the app doesn't need.

## Stack

- **Backend** (`api/`) — Zig web service exposing a REST API. JSON file storage
  for the MVP (`api/data.json`, backend-private), migrating to SQLite once the
  domain model stabilizes.
- **Frontend** (`web/`) — React on the Bun runtime. The Bun server bundles the
  app and proxies `/api/*` to the backend, so the browser only makes
  same-origin requests. It never touches `data.json` directly.
- **Contract** — `api/openapi.yaml` is the source of truth. The backend owns it;
  the frontend's typed client in `web/src/api.ts` is maintained by hand.

## MVP scope

The first entities to ship:

- **Pursuit** — name, type (`training` | `certification`), target date, status,
  started/completed timestamps.
- **Milestone** — name, date, `pending` | `achieved`; belongs to one pursuit.
- **Status** — explicit lifecycle: `planned → in_progress → completed`.

Deferred until later: cross-pursuit plans, tags, resources, renewals, progress
gauges, and the timeline view. See `docs/glossary/` for the full domain model.

## Requirements

- [Zig](https://ziglang.org/) **0.16.0** (backend)
- [Bun](https://bun.sh/) **1.3.14** (frontend)
- [mise](https://mise.jdx.dev/getting-started.html) manages the versions pinned
  in `mise.toml`. macOS and Playwright-supported Ubuntu/Debian are supported.

## Fresh machine setup

Install mise, clone this repository, then run from its root:

```bash
mise trust
mise install
mise exec -- ./scripts/setup.sh
mise exec -- ./scripts/verify.sh
mise exec -- ./scripts/dev.sh
```

Setup installs locked dependencies and Chromium; verification runs all gates
and needs port 3000 free. Both commands work for Codex and Claude Code without
shell activation. Neither touches your live data. See [setup and migration](docs/setup.md)
for Linux system dependencies, troubleshooting, personal agent settings, and
backing up and restoring training data.

## Build & run

The dev command above starts both processes, seeds the store on first run, and
stops both on interruption or when either exits. For individual processes, use
the commands below with the pinned tools on PATH (`mise exec -- <command>`).

### Backend

```bash
cd api
zig build          # compile
zig build run       # start the HTTP server on http://127.0.0.1:8080
zig build test -j1  # unit, acceptance, and HTTP integration; shared /tmp paths
```

Quick check once it's running:

```bash
curl -i http://127.0.0.1:8080/health
# HTTP/1.1 200 OK
# {"status":"ok"}
```

Unknown routes return a JSON `404`.

### Frontend

```bash
cd web
bun install --frozen-lockfile
bun dev             # dev server with HMR on http://127.0.0.1:3000
```

Open http://127.0.0.1:3000 — the page reads backend liveness via the proxied
`/api/health`. The backend URL is configurable with `BACKEND_URL`
(default `http://127.0.0.1:8080`); the frontend port with `PORT` (default
`3000`).

## Project layout

```
api/                  Zig backend
  build.zig           build / run / test entry points
  build.zig.zon       package manifest
  openapi.yaml        REST contract — source of truth
  src/main.zig        HTTP server + routing
web/                  Bun + React frontend
  server.ts           Bun server: serves the app, proxies /api -> backend
  index.html          app entry (bundled by Bun)
  src/                React components
docs/glossary/        domain model and project knowledge
```

## Environments

Two only: **local** (development) and **prod** (when deployed). No staging, no
separate test environment.

## Contributing notes

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `chore:`, `refactor:`, …).
- `api/openapi.yaml` is the contract: design or change it first, then implement
  against it.
