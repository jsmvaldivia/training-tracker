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

## Scope

- **Pursuit** — name, type (`training` | `certification`), target date,
  status, started/completed/expires timestamps, tags.
- **Milestone** — name, date, `pending` | `achieved`; belongs to one pursuit.
- **Status** — explicit lifecycle `planned → in_progress → completed`, plus
  `expired`, derived from `expires_at` on read.
- Dashboard with time and achievement gauges, and a timeline view.

Deferred: cross-pursuit plans, resources, and renewals (issues #26, #25,
#27). `docs/glossary/` holds the full domain model.

## Requirements

- [Zig](https://ziglang.org/) **0.16.0** (backend)
- [Bun](https://bun.sh/) **1.3.14** (frontend)
- [mise](https://mise.jdx.dev/getting-started.html) manages the versions pinned
  in `mise.toml`. macOS and Playwright-supported Ubuntu/Debian are supported.
- For the gate: `jq` and `lsof` (on macOS by default), and `oha` for its perf
  step.

## Fresh machine setup

Install mise, clone this repository, then run from its root:

```bash
mise trust
mise install
mise exec -- ./scripts/setup.sh
mise exec -- ./scripts/gate.sh
mise exec -- ./scripts/dev.sh
```

Setup installs locked dependencies and Chromium; the gate runs every check
and needs port 3000 free. Linux prerequisites, troubleshooting, and moving
live data between machines: [docs/setup.md](docs/setup.md).

## Build & run

The dev command starts both processes. For one at a time, with the pinned
tools on PATH (`mise exec -- <command>`):

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
bun test:e2e        # UI specs against a mocked API (Playwright)
bun test:e2e:live   # full stack: real API on a scratch store, no mocks
```

Open http://127.0.0.1:3000 — the page loads its pursuits through the proxied
`/api/pursuits` (`/api/health` exists for scripts and CI, the page does not
call it). The backend URL is configurable with `BACKEND_URL`
(default `http://127.0.0.1:8080`); the frontend port with `PORT` (default
`3000`).

## Performance snapshot

`scripts/bench.sh` measures the Zig API on a ReleaseSafe build against a
scratch copy of the seed (needs `oha`). `scripts/perf-snapshot.sh`, the gate's
`perf` step, compares a snapshot with the last five on the same platform in
`perf-snapshots.jsonl`, fails on a regression above 25 %, and appends the
passing line; commit that line with the change that produced it. Each script's
header says exactly what it measures and compares.

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

## Container image

Prod is one image (`docs/adr/0001-container-deployment.md`): the ReleaseSafe
API on `localhost:8080` inside the container, the Bun server on the only
exposed port `3000`, and the JSON store on the `/data` volume, seeded from
`api/data.seed.json` on the first start.

```bash
docker build -t training-tracker .
docker run --rm -p 3000:3000 -v "$(pwd)/data:/data" training-tracker
```

A `v*` tag builds and pushes `ghcr.io/jsmvaldivia/training-tracker:<version>`
and `:latest` and attaches the linux/x86_64 binary and the web bundle to a
GitHub Release (`.github/workflows/release.yml`), after the same gates the
backend and frontend workflows run.

## Deploy

Prod is the home k3s cluster (`docs/adr/0001-container-deployment.md`): one
Pod from the release image, the store on a `local-path` volume, a NodePort on
30300, LAN only. `deploy/k8s` holds the manifests; `scripts/deploy.sh` applies
them with the image tag of a release (needs `kubectl`, `curl`, `jq`):

```bash
scripts/deploy.sh v0.1.0
```

It runs from a machine whose kubeconfig reaches the cluster (`KUBE_CONTEXT`
picks a context). It reads the pursuit count, applies the manifests with the
tag set in a throwaway overlay, waits for the rollout, and fails unless
`GET /api/health` returns 200 and the count is unchanged. The checks target
`PROD_URL`, by default the first node's IP on the NodePort.

First deploy: the GHCR package must be public (`release.yml` header), the
store starts from `api/data.seed.json`, and the volume pins the Pod to the
node that holds it. To start from your live data instead, with nobody using
the app, copy it into the volume and restart:

```bash
kubectl -n training-tracker cp api/data.json "$(kubectl -n training-tracker get pod -l app=training-tracker -o jsonpath='{.items[0].metadata.name}'):/data/data.json"
kubectl -n training-tracker rollout restart deployment/training-tracker
```
