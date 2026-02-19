#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# run.sh — Spin up the forward proxy demo using podman
#
#   mock-ironic (curl)  →  envoy (:10000)  →  mock-bmc (:8000/:8443)
#         cluster net          both nets          oob net
#
# Usage:
#   ./run.sh            # no auth
#   ./run.sh --auth     # with RBAC + basic auth enabled
# ─────────────────────────────────────────────────────────────────────────────

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args
AUTH_MODE=false
ENVOY_CONFIG="envoy.yaml"
PROXY_URL="http://envoy-proxy:10000"
if [[ "${1:-}" == "--auth" ]]; then
    AUTH_MODE=true
    ENVOY_CONFIG="envoy-auth.yaml"
    PROXY_URL="http://ironic:changeme@envoy-proxy:10000"
    echo -e "${CYAN}▶ Auth mode ENABLED (RBAC + Basic Auth)${NC}"
fi

echo -e "${CYAN}▶ Cleaning up any previous run…${NC}"
podman rm -f mock-bmc envoy-proxy mock-ironic 2>/dev/null || true
podman network rm -f demo-cluster demo-oob 2>/dev/null || true

echo -e "${CYAN}▶ Creating networks…${NC}"
podman network create demo-cluster
podman network create demo-oob

echo -e "${CYAN}▶ Building mock BMC image…${NC}"
podman build -t mock-bmc:latest "${SCRIPT_DIR}/mock-bmc"

echo -e "${CYAN}▶ Starting mock-bmc (OOB network only)…${NC}"
podman run -d \
    --name mock-bmc \
    --hostname mock-bmc \
    --network demo-oob \
    -p 8000:8000 \
    -p 8443:8443 \
    mock-bmc:latest

echo -e "${CYAN}▶ Starting envoy forward proxy (cluster + OOB networks)…${NC}"
echo -e "${CYAN}  config: ${ENVOY_CONFIG}${NC}"
# Override entrypoint to skip chown /dev/stdout which fails in rootless podman
podman run -d \
    --name envoy-proxy \
    --entrypoint envoy \
    --network demo-oob \
    -v "${SCRIPT_DIR}/${ENVOY_CONFIG}:/etc/envoy/envoy.yaml:ro,Z" \
    -p 10000:10000 \
    -p 9901:9901 \
    docker.io/envoyproxy/envoy:v1.31-latest \
    -c /etc/envoy/envoy.yaml -l info

# Attach envoy to the cluster network too (bridges both nets)
podman network connect demo-cluster envoy-proxy

echo -e "${CYAN}▶ Starting mock-ironic (cluster network only — NO access to OOB)…${NC}"
echo -e "${CYAN}  proxy: ${PROXY_URL}${NC}"
podman run -d \
    --name mock-ironic \
    --network demo-cluster \
    -e HTTP_PROXY="${PROXY_URL}" \
    -e HTTPS_PROXY="${PROXY_URL}" \
    -e http_proxy="${PROXY_URL}" \
    -e https_proxy="${PROXY_URL}" \
    -e NO_PROXY=localhost,127.0.0.1 \
    -e no_proxy=localhost,127.0.0.1 \
    docker.io/curlimages/curl:latest \
    sh -c 'echo "Mock Ironic ready"; sleep infinity'

echo -e "${CYAN}▶ Waiting for containers to be healthy…${NC}"
sleep 3

echo -e "${GREEN}✓ All containers running:${NC}"
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
if [[ "$AUTH_MODE" == "true" ]]; then
    echo -e "${CYAN}Auth mode: RBAC + Basic Auth${NC}"
    echo -e "${CYAN}Now run:  ./test-auth.sh${NC}"
else
    echo -e "${CYAN}Now run:  ./test.sh${NC}"
fi
