# Metal3 Envoy Forward Proxy

Envoy forward proxy for [Metal3](https://metal3.io/) / Ironic BMC traffic.

Deploy **alongside** the [SUSE Edge Metal3 chart](https://github.com/suse-edge/charts/tree/main/charts/metal3/0.13.0) so that Ironic can reach out-of-band (OOB) BMC endpoints (Redfish / IPMI) that live on a separate network.

```
┌──────────────────────┐         ┌───────────────────┐         ┌─────────────┐
│   Ironic (SUSE Edge) │         │  Envoy Forward    │         │   BMC       │
│                      │         │  Proxy            │         │  (Redfish)  │
│  HTTP_PROXY=envoy    │────────▶│  :10000           │────────▶│  :443       │
│  HTTPS_PROXY=envoy   │  HTTP/  │  dynamic_forward  │  TCP    │  OOB        │
│                      │ CONNECT │  _proxy           │         │  network    │
└──────────────────────┘         └───────────────────┘         └─────────────┘
      cluster network              MetalLB VIP on               BMC / OOB
                                   OOB network                  network
```

## Table of Contents

- [How it Works](#how-it-works)
- [Example Network Layout](#example-network-layout)
  - [The Three Networks](#the-three-networks)
  - [The Problem](#the-problem)
  - [The Solution](#the-solution-envoy-forward-proxy-with-metallb)
  - [How IPs Map to Configuration](#how-the-ip-addresses-map-to-configuration)
  - [NO_PROXY Explained](#what-about-no_proxy)
- [Part 1 — Local Demo (Podman)](#part-1--local-demo-podman)
  - [What the Demo Proves](#what-the-demo-proves)
  - [Demo Architecture](#demo-architecture)
  - [Components](#demo-components)
  - [Running the Demo](#running-the-demo)
  - [Running the Auth Demo](#running-the-auth-demo)
  - [How the Demo Maps to Production](#how-the-demo-maps-to-production)
- [Part 2 — Kubernetes Production Deployment](#part-2--kubernetes-production-deployment)
  - [Prerequisites](#prerequisites)
  - [Quick Start](#quick-start)
  - [MetalLB Configuration](#metallb-configuration)
  - [Integrating with SUSE Edge Metal3 Chart](#integrating-with-suse-edge-metal3-chart)
  - [End-to-End Request Lifecycle](#end-to-end-request-lifecycle)
  - [Verification](#verification)
- [Security](#security)
- [Configuration Reference](#configuration-reference)
- [Troubleshooting](#troubleshooting)

---

## How it Works

1. **Ironic** (deployed by the SUSE Edge chart) uses the Python `sushy` library to manage bare-metal nodes via Redfish.
2. `sushy` uses Python `requests`, which natively honours `HTTP_PROXY` / `HTTPS_PROXY` environment variables.
3. The SUSE Edge chart provides `ironicExtraEnv` to inject arbitrary env vars into the Ironic pod ConfigMap.
4. **This chart** deploys Envoy configured as a [dynamic forward proxy](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/dynamic_forward_proxy_filter), resolving the destination host from each request's `Host` header (or CONNECT target).
5. **HTTP traffic** (e.g. `http://bmc-host:8000/redfish/v1`) is forwarded directly — Envoy reads the Host header, resolves DNS, and proxies the request.
6. **HTTPS traffic** (e.g. `https://bmc-host:443/redfish/v1`) uses HTTP CONNECT tunneling — the client sends `CONNECT bmc-host:443`, Envoy establishes a raw TCP tunnel, and the client negotiates TLS end-to-end. Envoy never decrypts the TLS.
7. Every proxied request is logged to stdout with source, destination, status, and timing (audit trail).

---

## Example Network Layout

If you're not sure what "OOB network" or "pod CIDR" means, this section walks through a concrete example with real IP addresses.

### The three networks

A typical bare-metal Kubernetes setup has (at least) three networks. Think of them as three separate Ethernet switches that different devices are plugged into:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  NETWORK 1: Kubernetes Pod Network (internal, virtual)                      │
│  Subnet: 10.244.0.0/16                                                     │
│  This is the cluster-internal network created by your CNI (Calico/Cilium).  │
│  Pods get IPs like 10.244.0.5, 10.244.1.12, etc.                           │
│  Only pods inside the cluster can talk to each other here.                  │
│                                                                             │
│  Who lives here:                                                            │
│    • Ironic pod          10.244.0.5                                         │
│    • BMO pod             10.244.0.6                                         │
│    • Envoy proxy pod     10.244.0.10                                        │
│    • (all other pods)                                                       │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  NETWORK 2: Provisioning / Host Network                                     │
│  Subnet: 192.168.1.0/24                                                     │
│  This is the "real" network your K8s nodes are on.                          │
│  Used for PXE boot, OS provisioning, and node-to-node traffic.              │
│                                                                             │
│  Who lives here:                                                            │
│    • K8s node 1          192.168.1.10   (NIC: eno1)                         │
│    • K8s node 2          192.168.1.11   (NIC: eno1)                         │
│    • K8s node 3          192.168.1.12   (NIC: eno1)                         │
│    • Ironic endpoint     192.168.1.100  (ironicIP)                          │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  NETWORK 3: OOB / BMC Network (out-of-band management)                     │
│  Subnet: 10.10.0.0/24                                                      │
│  This is a SEPARATE physical network for server management.                 │
│  Each server has a dedicated BMC port (iDRAC, iLO, etc.)                    │
│  plugged into this network. Often a different NIC (eno2) on the             │
│  K8s nodes is also connected here.                                          │
│                                                                             │
│  Who lives here:                                                            │
│    • BMC for node 1      10.10.0.51:443   (iDRAC / Redfish)                │
│    • BMC for node 2      10.10.0.52:443   (iDRAC / Redfish)                │
│    • BMC for node 3      10.10.0.53:443   (iDRAC / Redfish)                │
│    • BMC for new node 4  10.10.0.54:443   (to be provisioned)              │
│    • OOB switch          10.10.0.1                                          │
│    • Envoy VIP (MetalLB) 10.10.0.200      ← the proxy's "foot" on OOB     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### The problem

Ironic (at `10.244.0.5` on the pod network) needs to talk to BMCs (at `10.10.0.51-54` on the OOB network). But **pods can't reach the OOB network directly** — they're on completely different subnets with no route between them.

### The solution: Envoy forward proxy with MetalLB

```
  Pod Network                                   OOB / BMC Network
  10.244.0.0/16                                 10.10.0.0/24

  ┌──────────────┐                              ┌─────────────────────┐
  │ Ironic Pod   │   HTTP CONNECT               │ BMC (node 4)        │
  │ 10.244.0.5   │──────────────────┐           │ 10.10.0.54:443      │
  │              │                  │           │ Redfish API         │
  │ HTTPS_PROXY= │                  │           └─────────────────────┘
  │  envoy:10000 │                  │           ┌─────────────────────┐
  └──────────────┘                  │           │ BMC (node 1)        │
                                    ▼           │ 10.10.0.51:443      │
                            ┌───────────────┐   └─────────────────────┘
                            │ Envoy Pod     │   ┌─────────────────────┐
                            │ 10.244.0.10   │──▶│ BMC (node 2)        │
                            │               │   │ 10.10.0.52:443      │
                            │ MetalLB VIP:  │   └─────────────────────┘
                            │ 10.10.0.200   │   ┌─────────────────────┐
                            │ (on OOB net)  │   │ BMC (node 3)        │
                            └───────────────┘   │ 10.10.0.53:443      │
                                                └─────────────────────┘
```

MetalLB assigns Envoy the IP `10.10.0.200` on the OOB network. This means Envoy can now reach `10.10.0.51`, `10.10.0.52`, etc. Meanwhile, Ironic talks to Envoy using its pod-network address. Envoy **bridges** the two networks.

### How the IP addresses map to configuration

| Address | Where it appears | What it means |
|---------|-----------------|---------------|
| `10.244.0.0/16` | `envoy.auth.rbac.allowedSourceCIDRs` | Pod network CIDR — restrict proxy use to pods only |
| `10.10.0.0/24` | `envoy.auth.rbac.allowedDestinations: ["10.10.0."]` | BMC subnet — only allow proxying to this range |
| `10.10.0.200` | `envoy.service.loadBalancerIP` | MetalLB VIP for Envoy on the OOB network |
| `10.10.0.200-210` | MetalLB `IPAddressPool` | Range of IPs MetalLB can assign on the OOB network |
| `10.10.0.51` | `BareMetalHost` CR `bmc.address` | A specific BMC's Redfish endpoint |
| `192.168.1.100` | `global.ironicIP` (SUSE Edge chart) | Ironic's endpoint on the provisioning network |
| `envoy-fwd-proxy-envoy.metal3-system.svc:10000` | `HTTP_PROXY` / `HTTPS_PROXY` in `ironicExtraEnv` | Envoy's in-cluster DNS name (pod network) |

### What about `NO_PROXY`?

`NO_PROXY` tells Ironic "don't use the proxy for these destinations". You want to skip the proxy for:

| `NO_PROXY` entry | Why |
|------------------|-----|
| `localhost` | Ironic talking to itself |
| `127.0.0.1` | Loopback |
| `::1` | IPv6 loopback |
| `.svc` | Any Kubernetes service (e.g. Ironic API, MariaDB) — these are in-cluster |
| `.svc.cluster.local` | Full form of the above |
| `192.168.1.0/24` | *(optional)* If Ironic needs to reach the provisioning network directly |

Everything NOT in `NO_PROXY` goes through the proxy — which is exactly what we want for BMC traffic on `10.10.0.x`.

### Quick mental model

```
"Where does the traffic go?"

  Ironic wants to reach 10.10.0.54:443 (a BMC)
    → 10.10.0.54 is NOT in NO_PROXY
    → so Ironic asks the proxy (HTTPS_PROXY=envoy:10000)
    → Envoy has a VIP on 10.10.0.200 so it CAN reach 10.10.0.54
    → Envoy opens a TCP tunnel → BMC responds → Ironic gets the data

  Ironic wants to reach mariadb.metal3-system.svc:3306 (the database)
    → .svc IS in NO_PROXY
    → so Ironic connects directly (no proxy involved)
```

---

## Part 1 — Local Demo (Podman)

The `local-demo/` directory provides a fully self-contained proof-of-concept that you can run on your laptop with [Podman](https://podman.io/) — no Kubernetes cluster, no real BMCs, no Metal3/Ironic required.

The demo replaces the real production components with lightweight mocks:

| Production Component | Demo Mock | Purpose |
|---------------------|-----------|---------|
| Ironic pod (sushy/requests) | `mock-ironic` — a `curl` container with `HTTP_PROXY` set | Simulates Ironic making Redfish calls through a proxy |
| Envoy Deployment + Service | `envoy-proxy` — same Envoy image with a local config file | Identical forward proxy behaviour |
| Physical BMC on OOB network | `mock-bmc` — Python Redfish server (HTTP :8000, HTTPS :8443) | Returns real Redfish JSON, supports power on/off |
| Cluster network (pod CIDR) | `demo-cluster` Podman network | mock-ironic and envoy-proxy live here |
| OOB / BMC network | `demo-oob` Podman network | envoy-proxy and mock-bmc live here |
| MetalLB VIP | Envoy attached to both networks | Bridges cluster ↔ OOB just like a VIP would |

### What the Demo Proves

1. **HTTP forwarding** — mock-ironic GETs Redfish endpoints (`/redfish/v1`, `/redfish/v1/Systems/1`) via the proxy
2. **HTTPS CONNECT tunneling** — TLS traffic to the mock BMC is tunneled through Envoy without decryption
3. **Network isolation** — mock-ironic CANNOT reach mock-bmc directly (it's on a different Podman network); traffic only flows via the proxy
4. **Power actions** — POST power on/off commands work through the proxy (HTTP and HTTPS)
5. **Audit logging** — every request appears in Envoy's stdout access logs with timestamp, method, host, status, source and destination
6. **RBAC + Basic Auth** (auth mode) — valid credentials pass, wrong/missing credentials get 401, disallowed destinations get 403

### Demo Architecture

The Podman demo mirrors the production network layout using two container networks instead of physical switches:

```
  "demo-cluster" network                        "demo-oob" network
  (like the K8s pod network 10.244.0.0/16)      (like the BMC network 10.10.0.0/24)

  ┌──────────────────────┐     ┌────────────────────────┐     ┌───────────────────────┐
  │   mock-ironic        │     │   envoy-proxy          │     │   mock-bmc            │
  │   (curlimages/curl)  │     │   (envoyproxy/envoy)   │     │   (python:3.12-slim)  │
  │                      │     │                        │     │                       │
  │ HTTP_PROXY=          │     │  Listener :10000       │     │  HTTP  :8000          │
  │  envoy-proxy:10000   │────▶│  Admin    :9901        │────▶│  HTTPS :8443          │
  │                      │     │                        │     │                       │
  │ Network: demo-cluster│     │  Networks:             │     │  Network: demo-oob    │
  │                      │     │   demo-cluster ← Ironic│     │                       │
  │ ✗ No route to        │     │   demo-oob    ← BMCs  │     │  Redfish API mock     │
  │   demo-oob           │     │  (bridges both)        │     │  with power state     │
  └──────────────────────┘     └────────────────────────┘     └───────────────────────┘
         │                              │                              │
  Like: Ironic pod               Like: MetalLB VIP             Like: real BMC
  on pod network                 bridging both nets             on OOB network
  (10.244.0.5)                   (10.10.0.200)                 (10.10.0.51)
```

Podman assigns IPs automatically (e.g. `10.89.0.x`). The key point is that `mock-ironic` and `mock-bmc` are on **different** networks — just like Ironic pods and BMCs are on different networks in production. The only path between them is through `envoy-proxy`.

### Demo Components

#### `mock-bmc/server.py` — Mock Redfish BMC

A Python HTTP server that simulates a real BMC's Redfish API:

- **HTTP** on port 8000 and **HTTPS** on port 8443 (self-signed TLS cert auto-generated at startup)
- Responds to Redfish endpoints: `/redfish/v1`, `/redfish/v1/Systems`, `/redfish/v1/Systems/1`, `/redfish/v1/Managers/1`
- Supports `POST .../Actions/ComputerSystem.Reset` — accepts `ForceOff`, `On`, `GracefulShutdown`, etc. and updates the `PowerState` in memory
- Returns proper Redfish JSON with `@odata.type`, `@odata.id`, OData headers

#### `envoy.yaml` — Envoy Forward Proxy Config (no auth)

A standalone Envoy configuration identical to what the Helm chart generates with default values:

- **Listener** on `:10000` — accepts both regular HTTP requests and HTTP CONNECT tunnels
- **`dynamic_forward_proxy`** filter — reads the `Host` header to resolve the destination dynamically (no need to pre-configure backends)
- **Access logging** to stdout — logs method, host, path, status, bytes, duration, and upstream host
- **Admin** on `:9901` — serves `/ready`, `/stats`, `/clusters`

#### `envoy-auth.yaml` — Envoy Forward Proxy Config (with auth)

Same as `envoy.yaml` but adds:

- **RBAC filter** — only allows destinations containing `mock-bmc` (blocks everything else with 403)
- **Lua filter** — bridges `Proxy-Authorization` → `Authorization` header (needed because HTTP proxy clients send `Proxy-Authorization` but Envoy's basic_auth filter checks `Authorization`)
- **Basic Auth filter** — validates username `ironic` / password `changeme` (SHA1 hash)

#### `run.sh` — Start Script

Creates isolated Podman networks and starts all three containers:

1. Creates `demo-cluster` and `demo-oob` Podman networks
2. Builds the `mock-bmc` image from `mock-bmc/Dockerfile`
3. Starts `mock-bmc` on `demo-oob` only
4. Starts `envoy-proxy` on `demo-oob`, then connects it to `demo-cluster` too (bridges both networks)
5. Starts `mock-ironic` on `demo-cluster` only, with `HTTP_PROXY` / `HTTPS_PROXY` pointing to `envoy-proxy:10000`

> **Note:** The Envoy entrypoint is overridden (`--entrypoint envoy`) to skip the default `docker-entrypoint.sh` which runs `chown /dev/stdout` — this fails in rootless Podman.

Use `--auth` flag to start with RBAC + basic auth:

```bash
./run.sh --auth
```

#### `test.sh` — Test Suite (no auth)

Runs 9 end-to-end tests via `podman exec mock-ironic curl ...`:

| # | Test | What it verifies |
|---|------|-----------------|
| 1 | HTTP GET `/redfish/v1` | Basic HTTP forwarding works |
| 2 | HTTP GET `/redfish/v1/Systems` | Collection endpoints work |
| 3 | HTTP GET `/redfish/v1/Systems/1` | Individual resource endpoints work |
| 4 | HTTPS GET `/redfish/v1` (TLS) | CONNECT tunneling for HTTPS works |
| 5 | HTTPS GET `/redfish/v1/Systems/1` (TLS) | CONNECT tunneling with TLS resources |
| 6 | HTTP POST power off (ForceOff) | Write operations through HTTP proxy |
| 7 | HTTP GET verify `PowerState=Off` | State changes persist |
| 8 | HTTPS POST power on (On) over TLS | Write operations through CONNECT tunnel |
| 9 | Direct access (no proxy) → fails | Network isolation is enforced |

After the tests, Envoy `/stats` are printed showing request counts, upstream connections, and DNS cache hits.

#### `test-auth.sh` — Test Suite (with auth)

Runs additional tests specific to authentication:

- ✓ Valid credentials (`ironic:changeme`) → requests succeed (HTTP and HTTPS)
- ✗ No credentials → HTTP 401 Unauthorized
- ✗ Wrong password → HTTP 401 Unauthorized
- ✗ Wrong username → HTTP 401 Unauthorized
- ✗ Valid credentials but disallowed destination → HTTP 403 Forbidden (RBAC)
- ✗ Direct access (no proxy) → connection fails (network isolation)

#### `teardown.sh` — Cleanup

Removes all containers and networks:

```bash
./teardown.sh
```

### Running the Demo

**Prerequisites:** [Podman](https://podman.io/) installed (rootless is fine).

```bash
cd local-demo

# 1. Start the demo
./run.sh

# 2. Run the tests (9 tests)
./test.sh

# 3. View the Envoy access logs (audit trail)
podman logs envoy-proxy

# 4. View BMC logs (shows what the "BMC" received)
podman logs mock-bmc

# 5. Tear down
./teardown.sh
```

Expected output from `./test.sh`:

```
╔══════════════════════════════════════════════════════════════╗
║  Metal3 Forward Proxy Demo                                 ║
║  mock-ironic → envoy (HTTP_PROXY) → mock-bmc (Redfish)    ║
╚══════════════════════════════════════════════════════════════╝

━━━ TEST: HTTP proxy — GET /redfish/v1 (Service Root) ━━━
→ curl -s --proxy http://envoy-proxy:10000 http://mock-bmc:8000/redfish/v1
{
  "@odata.type": "#ServiceRoot.v1_15_0.ServiceRoot",
  ...
}
✓ PASS
...
Results: 9 passed, 0 failed
```

Expected Envoy access log (`podman logs envoy-proxy`):

```
[2026-02-19T10:00:00.123Z] "GET mock-bmc:8000/redfish/v1 HTTP/1.1" 200 - 0 423 12ms "10.89.0.5:43210"
[2026-02-19T10:00:00.456Z] "CONNECT mock-bmc:8443 HTTP/1.1" 200 - 156 892 45ms "10.89.0.5:43211"
```

### Running the Auth Demo

```bash
cd local-demo

# 1. Start with authentication enabled
./run.sh --auth

# 2. Run the auth test suite
./test-auth.sh

# 3. Check Envoy logs — you'll see 401s and 403s for rejected requests
podman logs envoy-proxy

# 4. Tear down
./teardown.sh
```

### How the Demo Maps to Production

The demo is a 1:1 mapping of the production architecture. Every concept demonstrated locally works identically on Kubernetes:

| Demo (Podman) | Production (Kubernetes) | Example IPs |
|---------------|------------------------|-------------|
| `demo-cluster` Podman network | Kubernetes pod network (CNI) | `10.244.0.0/16` |
| `demo-oob` Podman network | Physical OOB/BMC network | `10.10.0.0/24` |
| Envoy attached to both networks | MetalLB VIP gives Envoy an IP on OOB | VIP `10.10.0.200` |
| `mock-ironic` curl container | Ironic pod with `HTTP_PROXY` / `HTTPS_PROXY` | `10.244.0.5` |
| `mock-bmc` Python server | Real BMC hardware (iDRAC, iLO, Redfish) | `10.10.0.51:443` |
| `envoy.yaml` local file | Envoy ConfigMap generated by the Helm chart | — |
| `envoy-auth.yaml` (RBAC + auth) | Helm chart with `envoy.auth.rbac.enabled: true` | — |
| DNS resolution via Podman networks | Pod DNS or custom `dnsResolvers` | `10.10.0.1:53` |
| Network isolation (separate Podman nets) | Kubernetes NetworkPolicy | — |

**Use the demo to:**
- Validate the proxy concept before deploying to your cluster
- Test Envoy config changes locally before rolling them into the Helm chart
- Debug Redfish request flows in a controlled environment
- Demonstrate the solution to your team

---

## Part 2 — Kubernetes Production Deployment

### Prerequisites

- Kubernetes cluster with [MetalLB](https://metallb.universe.tf/) (for a LoadBalancer VIP on the OOB network)
- [SUSE Edge Metal3 chart](https://github.com/suse-edge/charts) v0.13.0+
- Helm 3.x
- The Envoy pod must be able to reach the OOB/BMC network (via MetalLB VIP, host networking, or a CNI with routes to the BMC subnet)

### Quick Start

#### 1. Install the Envoy forward proxy

```bash
# Install the proxy chart (use fullnameOverride for shorter resource names)
helm install envoy-fwd-proxy ./metal3-chart \
  -n metal3-system --create-namespace \
  --set fullnameOverride=envoy-fwd-proxy \
  -f values-envoy.yaml
```

Example `values-envoy.yaml` with MetalLB VIP:

```yaml
envoy:
  service:
    type: LoadBalancer
    loadBalancerIP: "10.10.0.200"          # your MetalLB VIP on the OOB network
    annotations:
      metallb.universe.tf/address-pool: "oob-pool"
    externalTrafficPolicy: Local

  # Optional: pin DNS to an OOB DNS server that resolves BMC hostnames
  # dnsResolvers:
  #   - address: "10.10.0.1"
  #     port: 53

  auth:
    networkPolicy:
      enabled: true
    rbac:
      enabled: true
      allowedDestinations:
        - "10.10.0."       # only allow proxying to BMC subnet
      # allowedSourceCIDRs:
      #   - prefix: "10.244.0.0"
      #     len: 16
```

#### 2. Install / upgrade the SUSE Edge Metal3 chart with proxy settings

Create a values override file, e.g. `values-metal3.yaml`:

```yaml
global:
  ironicIP: "192.168.1.100"
  enable_tls: true
  enable_basicAuth: true

  metal3-ironic:
    ironicExtraEnv:
      HTTP_PROXY:  "http://envoy-fwd-proxy-envoy.metal3-system.svc:10000"
      HTTPS_PROXY: "http://envoy-fwd-proxy-envoy.metal3-system.svc:10000"
      NO_PROXY:    "localhost,127.0.0.1,::1,.svc,.svc.cluster.local"
```

> **Tip:** After `helm install`, the NOTES output prints the exact service name and proxy URL to copy.

```bash
helm install metal3 suse-edge/metal3 \
  --version 0.13.0 \
  -n metal3-system \
  -f values-metal3.yaml
```

### MetalLB Configuration

#### Why MetalLB?

The Envoy proxy needs an IP address on the OOB/BMC network so it can route traffic to the BMCs. MetalLB gives the Envoy Service a VIP on that network. Without it, Envoy would only be reachable inside the Kubernetes cluster and couldn't reach the BMCs on the external OOB network.

#### Typical physical wiring

Most bare-metal servers have at least two NICs. Here's how they're usually connected:

```
  K8s Node (e.g. Dell PowerEdge R640)
  ┌────────────────────────────────────────────┐
  │                                            │
  │  NIC 1 (eno1) ──── Provisioning switch     │   192.168.1.0/24
  │                     (PXE, OS install,      │   K8s node IP: 192.168.1.10
  │                      K8s API, pod traffic) │
  │                                            │
  │  NIC 2 (eno2) ──── OOB / BMC switch       │   10.10.0.0/24
  │                     (management traffic    │   No host IP needed — MetalLB
  │                      to BMC ports)         │   advertises VIPs on this NIC
  │                                            │
  │  BMC port    ──── OOB / BMC switch         │   10.10.0.51
  │  (iDRAC/iLO)      (same switch as eno2)    │   (dedicated management port)
  │                                            │
  └────────────────────────────────────────────┘
```

MetalLB L2 mode advertises the Envoy VIP (`10.10.0.200`) on `eno2`, so when Envoy sends a packet to `10.10.0.51`, it goes out via `eno2` → OOB switch → BMC.

#### MetalLB L2 Mode Example

```yaml
# metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: oob-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.10.0.200-10.10.0.210    # IPs on your OOB/BMC network
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: oob-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - oob-pool
  interfaces:
    - eno2                        # NIC connected to the OOB network
```

#### Helm values to request the VIP

```yaml
envoy:
  service:
    type: LoadBalancer
    loadBalancerIP: "10.10.0.200"
    annotations:
      metallb.universe.tf/address-pool: "oob-pool"
    externalTrafficPolicy: Local
```

`externalTrafficPolicy: Local` preserves client source IPs — important if you use Envoy RBAC source CIDR rules.

### Integrating with SUSE Edge Metal3 Chart

The [SUSE Edge Metal3 chart v0.13.0](https://github.com/suse-edge/charts/tree/main/charts/metal3/0.13.0) provides an `ironicExtraEnv` escape hatch that injects environment variables into the Ironic ConfigMap:

```yaml
# In the SUSE Edge chart's ironic subchart values.yaml:
ironicExtraEnv: {}    # <-- this is what we use
```

This ConfigMap is loaded via `envFrom` into all Ironic containers (ironic, ironic-httpd, ironic-dnsmasq). Python `requests` (used by sushy) honours `HTTP_PROXY` and `HTTPS_PROXY` natively.

**Important:** BMO (baremetal-operator) does NOT talk to BMCs directly. BMO talks to the Ironic API (in-cluster). Ironic then uses sushy to reach the BMCs. So proxy settings only need to be on the Ironic containers.

#### Full deployment example

```bash
# 1. Create namespace
kubectl create namespace metal3-system

# 2. Deploy MetalLB IP pool for the OOB network
kubectl apply -f metallb-oob-pool.yaml

# 3. Deploy the Envoy forward proxy
helm install envoy-fwd-proxy ./metal3-chart \
  -n metal3-system \
  --set fullnameOverride=envoy-fwd-proxy \
  --set envoy.service.loadBalancerIP=10.10.0.200 \
  --set 'envoy.service.annotations.metallb\.universe\.tf/address-pool=oob-pool' \
  --set 'envoy.auth.rbac.allowedDestinations[0]=10.10.0.'

# 4. Deploy the SUSE Edge Metal3 chart with proxy settings
#    The Envoy service will be: envoy-fwd-proxy-envoy.metal3-system.svc:10000
helm install metal3 suse-edge/metal3 \
  --version 0.13.0 \
  -n metal3-system \
  --set global.ironicIP=192.168.1.100 \
  --set "metal3-ironic.ironicExtraEnv.HTTP_PROXY=http://envoy-fwd-proxy-envoy.metal3-system.svc:10000" \
  --set "metal3-ironic.ironicExtraEnv.HTTPS_PROXY=http://envoy-fwd-proxy-envoy.metal3-system.svc:10000" \
  --set "metal3-ironic.ironicExtraEnv.NO_PROXY=localhost\,127.0.0.1\,::1\,.svc\,.svc.cluster.local"
```

### End-to-End Request Lifecycle

Here is exactly what happens when Ironic manages a bare-metal server:

```
  Kubernetes Cluster                          OOB / BMC Network
 ┌─────────────────────────────────────┐     ┌──────────────────────┐
 │                                     │     │                      │
 │  BMO ──API──▶ Ironic               │     │   BMC (iDRAC/iLO)    │
 │               │                     │     │   10.10.0.50:443     │
 │               │ HTTPS_PROXY=envoy   │     │                      │
 │               │                     │     │                      │
 │               ▼                     │     │                      │
 │         HTTP CONNECT to             │     │                      │
 │         envoy-fwd-proxy:10000       │     │                      │
 │               │                     │     │                      │
 │               ▼                     │     │                      │
 │         Envoy (pod)                 │     │                      │
 │          ├─ RBAC check              │     │                      │
 │          ├─ DNS resolve 10.10.0.50  │     │                      │
 │          ├─ access log to stdout    │     │                      │
 │          └─ TCP connect ────────────┼─VIP─┼──▶ 10.10.0.50:443   │
 │                                     │     │       │              │
 │                                     │     │       ▼              │
 │                                     │     │  TLS handshake       │
 │                                     │     │  GET /redfish/v1/... │
 │         ◀──── tunnel response ──────┼─────┼──                    │
 │                                     │     │                      │
 └─────────────────────────────────────┘     └──────────────────────┘
```

Step by step:

1. **BMO** creates/updates a `BareMetalHost` CR → tells the Ironic API "inspect this host at `redfish://10.10.0.50/redfish/v1/Systems/1`"
2. **Ironic** (sushy) sees `HTTPS_PROXY=http://envoy-fwd-proxy-envoy:10000` in its environment
3. Python `requests` sends `CONNECT 10.10.0.50:443 HTTP/1.1` to the Envoy proxy
4. **Envoy** receives the CONNECT request:
   - RBAC filter checks if `10.10.0.50` matches `allowedDestinations` → ✓ allowed
   - DNS resolves `10.10.0.50` (already an IP, no DNS needed)
   - Access log: `[timestamp] "CONNECT 10.10.0.50:443 HTTP/1.1" 200 ... src=10.244.0.5:54321 dst="10.10.0.50:443"`
   - Establishes a raw TCP tunnel to `10.10.0.50:443` via the MetalLB VIP
5. **Ironic/sushy** negotiates TLS through the tunnel directly with the BMC
6. **BMC** responds with Redfish JSON
7. Response flows back through the tunnel → Envoy → Ironic

### Verification

```bash
# Check Envoy pod is running
kubectl get pods -n metal3-system -l app.kubernetes.io/name=envoy-proxy

# Check MetalLB assigned the VIP
kubectl get svc -n metal3-system -l app.kubernetes.io/name=envoy-proxy

# Tail the Envoy access logs (audit trail)
kubectl logs -n metal3-system -l app.kubernetes.io/name=envoy-proxy -f

# Check Envoy stats
kubectl port-forward svc/envoy-fwd-proxy-envoy 9901 -n metal3-system
curl http://localhost:9901/stats | grep forward_proxy

# Verify proxy env vars are set on the Ironic pod
kubectl exec -n metal3-system deploy/metal3-ironic -- env | grep -i proxy
```

---

## Security

This chart provides defence-in-depth:

| Layer | Mechanism | What it does |
|-------|-----------|-------------|
| **NetworkPolicy** | `envoy.auth.networkPolicy.enabled: true` | Only pods matching the Ironic label selector can reach the Envoy proxy port. All other pods are blocked at the CNI level. |
| **Envoy RBAC** | `envoy.auth.rbac.enabled: true` | Restricts which destination hosts (BMC subnets) can be proxied to, and optionally restricts source CIDRs. Requests to disallowed destinations get HTTP 403. |
| **Access Logs** | `envoy.accessLog.enabled: true` | Full audit trail to stdout: timestamp, method, host, path, response code, source IP, upstream host, bytes, duration. |
| **MetalLB** | Service type LoadBalancer | Envoy gets a dedicated VIP on the OOB network — no need for `hostNetwork`. |

### Why not basic auth?

The SUSE Edge Metal3 chart's `ironicExtraEnv` injects `HTTP_PROXY` / `HTTPS_PROXY` as simple URLs. While Python `requests` supports `http://user:pass@proxy:port` (and would send a `Proxy-Authorization` header), Envoy's HTTP CONNECT handling doesn't natively validate `Proxy-Authorization` — it requires a Lua filter hack to bridge `Proxy-Authorization` → `Authorization` for the `basic_auth` filter. This is fragile and not recommended for production. Use NetworkPolicy + RBAC instead.

The basic auth option is available (`envoy.auth.basicAuth.enabled: true`) if you need it, but consider it experimental.

### What is logged (audit trail)?

**HTTP requests** (full visibility):
```
[2026-02-18T12:00:00.000Z] "GET mock-bmc:8000/redfish/v1/Systems/1 HTTP/1.1" 200 - 0 423 12 src=10.244.0.5:54321 dst="10.10.0.50:8000"
```

**HTTPS CONNECT tunnels** (destination + bytes only):
```
[2026-02-18T12:00:01.000Z] "CONNECT mock-bmc:8443 HTTP/1.1" 200 - 156 892 45 src=10.244.0.5:54322 dst="10.10.0.50:8443"
```

For HTTPS, Envoy sees the destination host:port and byte counts, but NOT the request path or payload (the TLS tunnel is opaque). This is normal and expected for CONNECT proxying.

---

## Configuration Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `envoy.image.repository` | `envoyproxy/envoy` | Envoy container image |
| `envoy.image.tag` | `v1.31-latest` | Envoy image tag |
| `envoy.replicas` | `1` | Number of Envoy replicas |
| `envoy.listenerPort` | `10000` | Port Envoy listens on for proxy traffic |
| `envoy.adminPort` | `9901` | Port for Envoy admin/metrics |
| `envoy.dnsLookupFamily` | `V4_ONLY` | DNS resolution: V4_ONLY, V6_ONLY, V4_PREFERRED, ALL |
| `envoy.dnsResolvers` | `[]` | Custom upstream DNS servers for BMC name resolution |
| `envoy.logLevel` | `info` | Envoy log level |
| `envoy.connectTimeout` | `5s` | Upstream connect timeout |
| `envoy.timeout` | `60s` | Request timeout |
| `envoy.accessLog.enabled` | `true` | Enable access logging to stdout |
| `envoy.service.type` | `LoadBalancer` | Service type (LoadBalancer for MetalLB, ClusterIP for internal only) |
| `envoy.service.port` | `10000` | Service port |
| `envoy.service.loadBalancerIP` | `""` | MetalLB VIP to request |
| `envoy.service.annotations` | `{}` | Service annotations (e.g. MetalLB pool) |
| `envoy.service.externalTrafficPolicy` | `Local` | Preserve source IP (Local) or allow SNAT (Cluster) |
| `envoy.service.exposeAdmin` | `false` | Expose admin port on the Service |
| `envoy.auth.networkPolicy.enabled` | `true` | Create NetworkPolicy restricting access to Envoy |
| `envoy.auth.networkPolicy.ironicPodSelector` | `{app.kubernetes.io/name: ironic}` | Label selector for Ironic pods |
| `envoy.auth.rbac.enabled` | `true` | Enable Envoy RBAC filter |
| `envoy.auth.rbac.allowedDestinations` | `[]` | Allowed destination hosts/subnets (empty = any) |
| `envoy.auth.rbac.allowedSourceCIDRs` | `[]` | Allowed source CIDRs (empty = any) |
| `envoy.auth.basicAuth.enabled` | `false` | Enable basic auth (experimental, not recommended) |
| `envoy.hostNetwork` | `false` | Use host networking |
| `envoy.resources` | requests: 100m/128Mi, limits: 500m/256Mi | Resource requests/limits |
| `envoy.nodeSelector` | `{}` | Node selector |
| `envoy.tolerations` | `[]` | Tolerations |

---

## Troubleshooting

### Envoy pod not ready

```bash
kubectl logs -n metal3-system -l app.kubernetes.io/name=envoy-proxy
kubectl describe pod -n metal3-system -l app.kubernetes.io/name=envoy-proxy
```

### MetalLB not assigning VIP

```bash
kubectl get svc -n metal3-system -l app.kubernetes.io/name=envoy-proxy
kubectl get ipaddresspool -n metallb-system
kubectl logs -n metallb-system -l app=metallb,component=controller
```

### Ironic can't reach BMC

```bash
# Check proxy env vars are set on the Ironic pod
kubectl exec -n metal3-system deploy/metal3-ironic -- env | grep -i proxy

# Check Envoy access logs for the request
kubectl logs -n metal3-system -l app.kubernetes.io/name=envoy-proxy | tail -20

# Check Envoy can resolve the BMC hostname
kubectl exec -n metal3-system -l app.kubernetes.io/name=envoy-proxy -- curl -s http://localhost:9901/clusters | grep -A5 dynamic_forward_proxy
```

### NetworkPolicy blocking traffic

```bash
# Temporarily disable to test
helm upgrade envoy-fwd-proxy ./metal3-chart \
  -n metal3-system \
  --set fullnameOverride=envoy-fwd-proxy \
  --set envoy.auth.networkPolicy.enabled=false
```

### Resource names too long

Use `fullnameOverride` to keep names short:

```bash
helm install envoy-fwd-proxy ./metal3-chart \
  -n metal3-system \
  --set fullnameOverride=envoy-fwd-proxy
```

This produces resources named `envoy-fwd-proxy-envoy` instead of `envoy-fwd-proxy-metal3-envoy-fwd-proxy-envoy`.

### Podman demo: Envoy exits immediately

If the Envoy container exits with "chown: changing ownership of '/dev/stdout': Permission denied", you're hitting a rootless Podman limitation. The `run.sh` script already works around this by overriding the entrypoint. Make sure you're using the latest version of `run.sh`.

### Podman demo: tests show "connection refused"

Wait a few seconds after `./run.sh` for all containers to start, then retry `./test.sh`. You can check container status with:

```bash
podman ps -a --format "table {{.Names}}\t{{.Status}}"
podman logs envoy-proxy
podman logs mock-bmc
```

## File Structure

```
metal3-chart/
├── Chart.yaml                        # Helm chart metadata
├── values.yaml                       # Default values (all configurable)
├── README.md                         # This file
├── templates/
│   ├── _helpers.tpl                  # Template helpers (names, labels)
│   ├── envoy-configmap.yaml          # Envoy configuration (dynamic forward proxy)
│   ├── envoy-deployment.yaml         # Envoy Deployment
│   ├── envoy-service.yaml            # Envoy Service (ClusterIP or LoadBalancer)
│   ├── envoy-networkpolicy.yaml      # NetworkPolicy (restrict access to Ironic only)
│   └── NOTES.txt                     # Post-install instructions
└── local-demo/
    ├── run.sh                        # Start demo (Podman)
    ├── test.sh                       # Run tests (no auth)
    ├── test-auth.sh                  # Run tests (with auth)
    ├── teardown.sh                   # Clean up demo
    ├── envoy.yaml                    # Envoy config (no auth)
    ├── envoy-auth.yaml               # Envoy config (RBAC + basic auth)
    ├── docker-compose.yaml           # Alternative: Docker Compose setup
    └── mock-bmc/
        ├── Dockerfile                # Mock BMC container image
        └── server.py                 # Mock Redfish BMC server
```
