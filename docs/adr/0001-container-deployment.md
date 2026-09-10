# ADR 0001: prod runs as a single container image on the home k3s cluster

- Status: **Accepted** (issue #16)
- Date: 2026-09-10 (proposed 2026-09-05 with Fly.io; see alternatives)

## Context

The app is one user, two processes: the Zig API (JSON file store, no CORS,
binds `127.0.0.1:8080`) and the Bun server that serves the React app and
proxies `/api/*` to the API on the same origin. The app has no
authentication of any kind. The architecture decisions in `AGENTS.md` rule
out infrastructure the app does not need, and there are exactly two
environments, local and prod.

The owner already runs a k3s cluster on four Raspberry Pis (arm64) at home
for other apps, operates it with `kubectl`, and uses this app from the home
network only. The budget for hosting is zero.

## Decision

Prod is **one container image**, run as **one Pod on the existing home k3s
cluster**, reachable **from the LAN only**.

The image, built from the repository's `Dockerfile`:

- the ReleaseSafe Zig API, statically linked (musl), started by the
  entrypoint on `localhost:8080` — never exposed;
- the Bun server on port **3000**, the only port the container exposes,
  proxying `/api/*` to the API next to it;
- the JSON store at **`/data/data.json`** (`DATA_PATH`), seeded from
  `api/data.seed.json` on the first start only;
- published by the release workflow to GHCR as
  `ghcr.io/jsmvaldivia/training-tracker:<version>` for `linux/amd64` and
  `linux/arm64` (the arm64 half is issue #57). The package is public, so the
  cluster pulls it without a secret.

The cluster side (`deploy/k8s`, plain manifests with a `kustomization.yaml`,
namespace `training-tracker`; issue #18):

- a Deployment with `replicas: 1` and `strategy: Recreate`. The store is one
  file with one writer; a rolling update would run two Pods against it;
- liveness and readiness probes on `GET /api/health` (Kubernetes ignores the
  Dockerfile `HEALTHCHECK`);
- a `local-path` PersistentVolumeClaim mounted at `/data`. It binds to one
  node, which pins the Pod to that Pi and its disk;
- a NodePort Service, **30300 → 3000**. The app is `http://<pi>.local:30300`,
  plain HTTP. The LAN is the trust boundary.

Deploy = `scripts/deploy.sh <version>` from a machine that has the cluster's
kubeconfig: set the image tag, `kubectl apply -k`, wait for the rollout,
then check `GET /api/health` and compare the pursuit count with the value
read before the deploy (issue #18).

Why this and not less: the cluster exists and is the platform the owner
already operates; Docker beside it would be a second runtime on the same
hardware. Why not more: one Pod, one PVC, one NodePort is the smallest k3s
shape that runs the image unchanged.

## Alternatives considered

- **Fly.io** (the original proposal): a single container with a persistent
  volume and TLS termination for a few dollars a month. Rejected: the app is
  used from home only, the budget is zero, and a public host needs an access
  layer the app does not have. Revive it if prod must be reachable away from
  home, and only after an access layer (Tailscale, Cloudflare Access, or
  auth in the Bun server) exists.
- **Plain Docker on a Pi or on the dev Mac**: the same image with
  `-v <dir>:/data`. Smaller than Kubernetes on paper, but a second runtime
  next to the cluster the owner already runs. On the dev Mac it would also
  compete with dev and verify for port 3000. The `docker run` line in the
  README stays as the local way to try the image.
- **VM with bare binaries** (systemd units for the API and Bun): more moving
  parts to provision and patch for the same two processes; no advantage at
  this size.
- **Cloudflare Workers / Pages**: the API needs a local file and a
  long-lived process; the store and the Zig binary do not fit the platform
  without a rewrite.
- **Two containers in one Pod** (API and web as sidecars sharing localhost):
  more idiomatic, separate logs and probes, but two images and a second
  entrypoint for no user-visible gain. Revisit if logs or probes ever need
  separating.

## Consequences

- Release = push a `v*` tag (`.github/workflows/release.yml`, issue #17).
  Deploy = run `scripts/deploy.sh` (issue #18). GitHub Actions cannot reach
  the LAN, so the two steps stay separate.
- The Pod is pinned to the Pi that holds the PVC. If that Pi or its disk
  fails, the store goes with it. Backup = a manual copy of `/data/data.json`
  from the Pod (`kubectl cp`); no schedule. Accepted for now; Longhorn or
  NFS would change only the storage class.
- The SQLite migration replaces `data.json` on the same PVC; the image, the
  manifests, and the cluster stay.
- Nothing in the app checks who is calling. Any device on the LAN can read
  and write the store. Moving the boundary (Tailscale, a public host)
  requires an access layer first.
- `AGENTS.md`'s "two environments" note stays accurate: local is the dev
  Mac, prod is the cluster.
