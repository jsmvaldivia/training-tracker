# ADR 0001: prod runs as a single container image

- Status: **Proposed** — the hosting provider is the owner's call (issue #16)
- Date: 2026-09-05

## Context

The app is one user, two processes: the Zig API (JSON file store, no CORS,
binds `127.0.0.1:8080`) and the Bun server that serves the React app and
proxies `/api/*` to the API on the same origin. The architecture decisions
in `AGENTS.md` rule out infrastructure the app does not need, and there are
exactly two environments, local and prod.

## Decision

Prod is **one container image** built from the repository's `Dockerfile`:

- the ReleaseSafe Zig API, statically linked (`x86_64-linux-musl`), started
  by the entrypoint on `localhost:8080` — never exposed;
- the Bun server on port **3000**, the only exposed port, proxying `/api/*`
  to the API next to it;
- the JSON store on a mounted volume at **`/data`** (`DATA_PATH=/data/data.json`),
  seeded from `api/data.seed.json` on the first start only.

Hosting provider: **Fly.io** (proposed). It runs a single container with a
persistent volume, terminates TLS, and its smallest machine fits a one-user
app. Alternative with the same image: a home server running Docker with
`-v /srv/training-tracker:/data`; nothing in the image depends on Fly.

Why one image: it matches the same-origin proxy design (no CORS, no second
host name); there is one thing to deploy, roll back, and back up (the
volume); and the release workflow already builds and publishes it (issue #17).

## Alternatives considered

- **VM with bare binaries** (systemd units for the API and Bun): more moving
  parts to provision and patch for the same two processes; no advantage at
  this size.
- **Cloudflare Workers / Pages**: the API needs a local file and a long-lived
  process; the store and the Zig binary do not fit the platform without a
  rewrite. The SQLite migration would only change what sits on the volume,
  not the shape of the deployment.

## Consequences

- Deploy = push a `v*` tag (issue #17 builds the image; issue #18 deploys it
  and smoke-checks `GET /api/health`).
- Backups = copy `/data/data.json` from the volume (`docs/setup.md`,
  "Transfer live training data").
- The SQLite migration replaces `data.json` on the same volume; the image
  and the provider stay.
