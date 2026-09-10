#!/usr/bin/env bash
set -euo pipefail

# Deploy one released version to prod (issue #18): the home k3s cluster
# (docs/adr/0001-container-deployment.md). GitHub Actions cannot reach the
# LAN, so this runs from a machine whose kubeconfig reaches the cluster.
#
#   scripts/deploy.sh v0.1.0      the release tag; the image tag is 0.1.0
#
#   KUBE_CONTEXT   kubectl context (default: the current one; printed first)
#   PROD_URL       base URL for the checks (default: the first node's internal
#                  IP on the NodePort from deploy/k8s/service.yaml)
#   TIMEOUT        seconds to wait for the rollout and for /api/health (120)
#
# Reads the pursuit count, applies deploy/k8s with the image tag set in a
# throwaway overlay (the tracked kustomization stays untouched), waits for
# the rollout, then fails unless GET /api/health returns 200 and the count is
# unchanged. Runnable from anywhere; resolves paths relative to the repo root.
cd "$(dirname "$0")/.."

version="${1:-}"
[[ -n "$version" ]] || { echo "usage: scripts/deploy.sh v<version>" >&2; exit 2; }
tag="${version#v}"

namespace=training-tracker
image=ghcr.io/jsmvaldivia/training-tracker
TIMEOUT="${TIMEOUT:-120}"

for tool in kubectl curl jq; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required" >&2; exit 2; }
done

kube=(kubectl)
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  kube+=(--context "$KUBE_CONTEXT")
fi
context="$("${kube[@]}" config current-context)"
echo "deploying $image:$tag to context $context, namespace $namespace"

if [[ -z "${PROD_URL:-}" ]]; then
  node_ip="$("${kube[@]}" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  node_port="$(awk '/^ *nodePort:/ { print $2 }' deploy/k8s/service.yaml)"
  PROD_URL="http://$node_ip:$node_port"
fi
echo "checks against $PROD_URL"

count() { curl -sf --max-time 5 "$PROD_URL/api/pursuits?limit=1" | jq -r .total; }

before="$(count 2>/dev/null || true)"
if [[ -n "$before" ]]; then
  echo "pursuits before: $before"
else
  echo "no running version answered; first deploy, count check skipped"
fi

overlay="$(mktemp -d "${TMPDIR:-/tmp}/tt-deploy.XXXXXX")"
trap 'rm -rf "$overlay"' EXIT
cp -R deploy/k8s "$overlay/base"
cat > "$overlay/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [base]
images:
  - name: $image
    newTag: "$tag"
EOF

"${kube[@]}" apply -k "$overlay"
"${kube[@]}" -n "$namespace" rollout status "deployment/training-tracker" --timeout="${TIMEOUT}s"

healthy=""
for _ in $(seq 1 "$TIMEOUT"); do
  if curl -sf --max-time 5 "$PROD_URL/api/health" >/dev/null; then healthy=1; break; fi
  sleep 1
done
if [[ -z "$healthy" ]]; then
  echo "error: $PROD_URL/api/health did not return 200 within ${TIMEOUT}s" >&2
  exit 1
fi
echo "health: ok"

after="$(count)"
if [[ -n "$before" && "$after" != "$before" ]]; then
  echo "error: pursuit count changed across the deploy: $before -> $after (did the volume survive?)" >&2
  exit 1
fi
echo "pursuits after: $after"
echo "deployed $image:$tag"
