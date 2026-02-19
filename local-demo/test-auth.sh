#!/usr/bin/env bash
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# test-auth.sh — Test the forward proxy with RBAC + Basic Auth enabled
#
# Demonstrates:
#   ✓ Requests WITH valid credentials → succeed
#   ✗ Requests WITHOUT credentials → 401 Unauthorized
#   ✗ Requests with WRONG credentials → 401 Unauthorized
#   ✗ Requests to non-BMC destinations → 403 Forbidden (RBAC)
# ─────────────────────────────────────────────────────────────────────────────

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

run_test_expect_success() {
    local description="$1"
    shift
    echo -e "\n${CYAN}━━━ TEST: ${description} ━━━${NC}"
    echo -e "${YELLOW}→ $*${NC}"
    if output=$(podman exec mock-ironic "$@" 2>&1); then
        echo "$output" | head -20
        echo -e "${GREEN}✓ PASS (request succeeded as expected)${NC}"
        ((pass++))
    else
        echo "$output" | head -10
        echo -e "${RED}✗ FAIL (should have succeeded)${NC}"
        ((fail++))
    fi
}

run_test_expect_status() {
    local description="$1"
    local expected_code="$2"
    shift 2
    echo -e "\n${CYAN}━━━ TEST: ${description} ━━━${NC}"
    echo -e "${YELLOW}→ $*${NC}"
    output=$(podman exec mock-ironic "$@" 2>&1) || true
    http_code=$(echo "$output" | tail -1)
    body=$(echo "$output" | head -n -1)
    echo "$body" | head -10
    if [[ "$http_code" == "$expected_code" ]]; then
        echo -e "${GREEN}✓ PASS (got HTTP ${http_code} as expected)${NC}"
        ((pass++))
    else
        echo -e "${RED}✗ FAIL (expected HTTP ${expected_code}, got ${http_code})${NC}"
        ((fail++))
    fi
}

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Forward Proxy Auth Demo (RBAC + Basic Auth)               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

# ═══════════════════════════════════════════════════════════════════════════════
# VALID AUTH — should succeed
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${GREEN}── Valid credentials (ironic:changeme) ──${NC}"

# curl with proxy auth embedded in URL (how Python requests sends it)
run_test_expect_success "HTTP + valid auth → GET /redfish/v1" \
    curl -s --proxy http://ironic:changeme@envoy-proxy:10000 \
    http://mock-bmc:8000/redfish/v1

run_test_expect_success "HTTPS CONNECT + valid auth → GET /redfish/v1 over TLS" \
    curl -s -k --proxy http://ironic:changeme@envoy-proxy:10000 \
    https://mock-bmc:8443/redfish/v1

run_test_expect_success "HTTP + valid auth → POST power action" \
    curl -s --proxy http://ironic:changeme@envoy-proxy:10000 \
    -X POST -H "Content-Type: application/json" \
    -d '{"ResetType": "ForceOff"}' \
    http://mock-bmc:8000/redfish/v1/Systems/1/Actions/ComputerSystem.Reset

# ═══════════════════════════════════════════════════════════════════════════════
# NO AUTH — should get 401
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${RED}── No credentials ──${NC}"

run_test_expect_status "HTTP + NO auth → should be 401 Unauthorized" "401" \
    curl -s --proxy http://envoy-proxy:10000 \
    -o /dev/null -w "%{http_code}" \
    http://mock-bmc:8000/redfish/v1

# ═══════════════════════════════════════════════════════════════════════════════
# WRONG AUTH — should get 401
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${RED}── Wrong credentials ──${NC}"

run_test_expect_status "HTTP + wrong password → should be 401" "401" \
    curl -s --proxy http://ironic:wrongpassword@envoy-proxy:10000 \
    -o /dev/null -w "%{http_code}" \
    http://mock-bmc:8000/redfish/v1

run_test_expect_status "HTTP + wrong username → should be 401" "401" \
    curl -s --proxy http://hacker:changeme@envoy-proxy:10000 \
    -o /dev/null -w "%{http_code}" \
    http://mock-bmc:8000/redfish/v1

# ═══════════════════════════════════════════════════════════════════════════════
# RBAC — valid auth but wrong destination — should get 403
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${RED}── Valid credentials but disallowed destination (RBAC) ──${NC}"

run_test_expect_status "HTTP + valid auth + non-BMC destination → should be 403 Forbidden" "403" \
    curl -s --proxy http://ironic:changeme@envoy-proxy:10000 \
    -o /dev/null -w "%{http_code}" \
    http://google.com/

# CONNECT to a blocked destination: curl may get 403 or report 000 (connection reset)
# because some curl versions can't parse the proxy error during CONNECT.
# Either means Envoy rejected it — check envoy logs for the 403.
echo -e "\n${CYAN}━━━ TEST: HTTPS CONNECT + valid auth + non-BMC dest → should be rejected ━━━${NC}"
echo -e "${YELLOW}→ curl CONNECT to google.com:443 via proxy${NC}"
if podman exec mock-ironic \
    curl -s -k --proxy http://ironic:changeme@envoy-proxy:10000 \
    --connect-timeout 5 https://google.com/ 2>&1 | head -5; then
    echo -e "${RED}✗ FAIL — CONNECT should have been blocked${NC}"
    ((fail++))
else
    echo -e "${GREEN}✓ PASS — CONNECT to non-BMC destination was rejected${NC}"
    ((pass++))

# ═══════════════════════════════════════════════════════════════════════════════
# NETWORK ISOLATION — no proxy, no access
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${RED}── Network isolation (no proxy) ──${NC}"

echo -e "\n${CYAN}━━━ TEST: Direct access (no proxy) → should fail ━━━${NC}"
if podman exec \
    -e http_proxy= -e HTTP_PROXY= -e https_proxy= -e HTTPS_PROXY= \
    mock-ironic curl -s --noproxy '*' --connect-timeout 3 http://mock-bmc:8000/redfish/v1 2>&1; then
    echo -e "${RED}✗ FAIL — direct connection should not work${NC}"
    ((fail++))
else
    echo -e "${GREEN}✓ PASS — network isolation confirmed${NC}"
    ((pass++))
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Results: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ $fail -gt 0 ]]; then
    echo -e "\n${YELLOW}Tip: check envoy logs with: podman logs envoy-proxy${NC}"
    exit 1
fi
