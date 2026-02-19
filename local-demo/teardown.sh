#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# teardown.sh — Clean up all demo containers and networks
# ─────────────────────────────────────────────────────────────────────────────

echo "Stopping and removing containers…"
podman rm -f mock-bmc envoy-proxy mock-ironic 2>/dev/null || true

echo "Removing networks…"
podman network rm -f demo-cluster demo-oob 2>/dev/null || true

echo "Done."
