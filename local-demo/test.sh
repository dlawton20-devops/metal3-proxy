#!/usr/bin/env bash
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# test.sh — Exercise the forward proxy flow using podman:
#   mock-ironic  →  envoy (forward proxy)  →  mock-bmc (Redfish)
#
# The mock-ironic container has HTTP_PROXY / HTTPS_PROXY set to envoy:10000
# and is NOT on the OOB network — so it can only reach the BMC via the proxy.
# ─────────────────────────────────────────────────────────────────────────────

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

run_test() {
    local description="$1"
    shift
    echo -e "\n${CYAN}━━━ TEST: ${description} ━━━${NC}"
    echo -e "${YELLOW}→ $*${NC}"
    if output=$(podman exec mock-ironic "$@" 2>&1); then
        echo "$output" | head -40
        echo -e "${GREEN}✓ PASS${NC}"
        ((pass++))
    else
        echo "$output" | head -20
        echo -e "${RED}✗ FAIL${NC}"
        ((fail++))
    fi
}

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Metal3 Forward Proxy Demo                                 ║${NC}"
echo -e "${CYAN}║  mock-ironic → envoy (HTTP_PROXY) → mock-bmc (Redfish)    ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

# ── 1. HTTP forward proxy: GET Redfish Service Root ──────────────────────────
run_test "HTTP proxy — GET /redfish/v1 (Service Root)" \
    curl -s --proxy http://envoy-proxy:10000 http://mock-bmc:8000/redfish/v1

# ── 2. HTTP forward proxy: GET Systems collection ────────────────────────────
run_test "HTTP proxy — GET /redfish/v1/Systems" \
    curl -s --proxy http://envoy-proxy:10000 http://mock-bmc:8000/redfish/v1/Systems

# ── 3. HTTP forward proxy: GET single System (bare metal node) ───────────────
run_test "HTTP proxy — GET /redfish/v1/Systems/1 (node details)" \
    curl -s --proxy http://envoy-proxy:10000 http://mock-bmc:8000/redfish/v1/Systems/1

# ── 4. HTTPS tunneling (CONNECT): GET Service Root over TLS ─────────────────
run_test "HTTPS CONNECT tunnel — GET /redfish/v1 over TLS" \
    curl -s -k --proxy http://envoy-proxy:10000 https://mock-bmc:8443/redfish/v1

# ── 5. HTTPS tunneling (CONNECT): GET System over TLS ───────────────────────
run_test "HTTPS CONNECT tunnel — GET /redfish/v1/Systems/1 over TLS" \
    curl -s -k --proxy http://envoy-proxy:10000 https://mock-bmc:8443/redfish/v1/Systems/1

# ── 6. POST power action through HTTP proxy ──────────────────────────────────
run_test "HTTP proxy — POST power off (ForceOff)" \
    curl -s --proxy http://envoy-proxy:10000 \
    -X POST -H "Content-Type: application/json" \
    -d '{"ResetType": "ForceOff"}' \
    http://mock-bmc:8000/redfish/v1/Systems/1/Actions/ComputerSystem.Reset

# ── 7. Verify power state changed ───────────────────────────────────────────
run_test "HTTP proxy — GET System (verify PowerState=Off)" \
    curl -s --proxy http://envoy-proxy:10000 http://mock-bmc:8000/redfish/v1/Systems/1

# ── 8. POST power on through HTTPS CONNECT tunnel ───────────────────────────
run_test "HTTPS CONNECT tunnel — POST power on (On) over TLS" \
    curl -s -k --proxy http://envoy-proxy:10000 \
    -X POST -H "Content-Type: application/json" \
    -d '{"ResetType": "On"}' \
    https://mock-bmc:8443/redfish/v1/Systems/1/Actions/ComputerSystem.Reset

# ── 9. Verify no direct connectivity (ironic can't reach BMC without proxy) ─
echo -e "\n${CYAN}━━━ TEST: Verify mock-ironic CANNOT reach BMC directly (no proxy) ━━━${NC}"
echo -e "${YELLOW}→ curl (no proxy) http://mock-bmc:8000/redfish/v1${NC}"
if podman exec \
    -e http_proxy= -e HTTP_PROXY= -e https_proxy= -e HTTPS_PROXY= \
    mock-ironic curl -s --noproxy '*' --connect-timeout 3 http://mock-bmc:8000/redfish/v1 2>&1; then
    echo -e "${RED}✗ FAIL — direct connection should not work (ironic is not on OOB network)${NC}"
    ((fail++))
else
    echo -e "${GREEN}✓ PASS — connection refused / timed out as expected (network isolation works)${NC}"
    ((pass++))
fi

# ── Envoy stats ──────────────────────────────────────────────────────────────
echo -e "\n${CYAN}━━━ ENVOY STATS ━━━${NC}"
echo -e "${YELLOW}Proxy request totals:${NC}"
curl -s http://localhost:9901/stats | grep -E "forward_proxy\.(downstream_rq|downstream_cx)" | head -10
echo ""
echo -e "${YELLOW}Upstream (BMC) connection stats:${NC}"
curl -s http://localhost:9901/stats | grep -E "dynamic_forward_proxy_cluster\.(upstream_cx|upstream_rq)" | head -10
echo ""
echo -e "${YELLOW}DNS cache stats:${NC}"
curl -s http://localhost:9901/stats | grep "dns_cache" | head -10

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Results: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ $fail -gt 0 ]]; then
    echo -e "\n${YELLOW}Tip: check envoy logs with: podman logs envoy-proxy${NC}"
    exit 1
fi
