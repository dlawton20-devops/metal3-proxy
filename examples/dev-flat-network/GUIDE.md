# Dev Flat Network — Step-by-Step Setup Guide

Deploy the Metal3 Envoy forward proxy on a **flat network** (single subnet, no separate OOB VLAN) for development and testing.

## Environment

```
  Flat Network: 10.2.83.0/24

  ┌─────────────────────────────────────────────┐
  │  Kubernetes Cluster                         │
  │                                             │
  │  Ironic LB VIP:       10.2.83.71            │   ← ironicIP
  │  Envoy Proxy LB VIP:  10.2.83.20            │   ← forward proxy
  │                                             │
  └──────────────────┬──────────────────────────┘
                     │
              10.2.83.0/24 flat network
                     │
  ┌──────────────────┴──────────────────────────┐
  │  VM Host: 10.2.83.181                       │
  │                                             │
  │  KVM Guest (mock bare-metal host)           │
  │    BMC endpoint: 10.2.83.76                 │   ← virtual Redfish BMC
  │                                             │
  └─────────────────────────────────────────────┘
```

| Component | IP | Purpose |
|-----------|-----|---------|
| Ironic VIP | `10.2.83.71` | MetalLB VIP — Ironic API for BMO |
| Envoy proxy VIP | `10.2.83.20` | MetalLB VIP — forward proxy for BMC traffic |
| VM host | `10.2.83.181` | Hosts the KVM guest |
| Mock BMC | `10.2.83.76` | Virtual BMC (Redfish) on the KVM guest |

### Traffic flow

```
  BMO → Ironic API (10.2.83.71)
          │
          │  Ironic needs to reach BMC at 10.2.83.76
          │  HTTPS_PROXY is set → route through proxy
          │
          ▼
  Ironic pod → CONNECT 10.2.83.76:443
          │
          │  sends to envoy-fwd-proxy-envoy.metal3-system.svc:10000
          │
          ▼
  Envoy (VIP 10.2.83.20)
    ├─ RBAC check: is 10.2.83.76 allowed? ✓
    ├─ access log: CONNECT 10.2.83.76:443 → stdout
    └─ TCP tunnel → 10.2.83.76:443
          │
          ▼
  Mock BMC (10.2.83.76) responds with Redfish JSON
```

---

## Prerequisites

- Kubernetes cluster on the `10.2.83.0/24` network
- [MetalLB](https://metallb.universe.tf/) installed
- [Helm 3.x](https://helm.sh/) installed
- The SUSE Edge Helm repo added:
  ```bash
  helm repo add suse-edge https://suse-edge.github.io/charts
  helm repo update
  ```
- A virtual BMC running on the KVM guest at `10.2.83.76` (e.g. [sushy-tools](https://docs.openstack.org/sushy-tools/latest/), [vbmc](https://docs.openstack.org/virtualbmc/latest/), or similar)

---

## Step 1 — Configure MetalLB IP Pool

Reserve the VIPs for Envoy and Ironic in MetalLB:

```bash
kubectl apply -f metallb-pool.yaml
```

This creates:
- `IPAddressPool` with `10.2.83.20/32` (Envoy) and `10.2.83.71/32` (Ironic)
- `L2Advertisement` so MetalLB ARPs for these IPs on the flat network

**Verify:**

```bash
kubectl get ipaddresspool -n metallb-system
#  NAME       AUTO ASSIGN   AVOID BUGGY IPS   ADDRESSES
#  dev-pool   true          false              ["10.2.83.20/32","10.2.83.71/32"]
```

---

## Step 2 — Install the Envoy Forward Proxy

```bash
helm install envoy-fwd-proxy ../../ \
  -n metal3-system --create-namespace \
  --set fullnameOverride=envoy-fwd-proxy \
  -f values-envoy.yaml
```

> If you cloned this repo elsewhere, replace `../../` with the path to the chart root (the directory containing `Chart.yaml`).

**Verify:**

```bash
# Envoy pod should be Running
kubectl get pods -n metal3-system -l app.kubernetes.io/name=envoy-proxy

# Service should show EXTERNAL-IP = 10.2.83.20
kubectl get svc -n metal3-system envoy-fwd-proxy-envoy
#  NAME                    TYPE           EXTERNAL-IP   PORT(S)
#  envoy-fwd-proxy-envoy   LoadBalancer   10.2.83.20    10000:xxxxx/TCP

# Quick connectivity test — curl the Envoy admin page
curl -s http://10.2.83.20:9901/ready
# Should return: LIVE
```

---

## Step 3 — Install the SUSE Edge Metal3 Chart

```bash
helm install metal3 suse-edge/metal3 \
  --version 0.13.0 \
  -n metal3-system \
  -f values-metal3.yaml
```

**Verify:**

```bash
# Ironic pod should be Running
kubectl get pods -n metal3-system -l app.kubernetes.io/name=ironic

# Ironic service should show EXTERNAL-IP = 10.2.83.71
kubectl get svc -n metal3-system -l app.kubernetes.io/name=ironic

# Proxy env vars should be set on the Ironic pod
kubectl exec -n metal3-system deploy/metal3-ironic -- env | grep -i proxy
#  HTTP_PROXY=http://10.2.83.20:10000
#  HTTPS_PROXY=http://10.2.83.20:10000
#  NO_PROXY=localhost,127.0.0.1,::1,.svc,.svc.cluster.local,10.2.83.71
```

---

## Step 4 — Create the BareMetalHost

Edit `mock-bmh.yaml` first:

1. Set `bootMACAddress` to your KVM guest's provisioning NIC MAC address
2. Set `bmc.address` to match your virtual BMC's URL/port (see comments in the file for examples)
3. Set the credentials in the Secret to match your virtual BMC's username/password

Then apply:

```bash
kubectl apply -f mock-bmh.yaml
```

**Verify:**

```bash
# BMH should move from registering → inspecting → available
kubectl get bmh -n metal3-system -w
#  NAME          STATE          CONSUMER   ONLINE   ERROR
#  mock-node-1   registering               true

# Watch it progress (may take a few minutes)
#  mock-node-1   inspecting                true
#  mock-node-1   available                 true
```

---

## Step 5 — Watch the Audit Trail

Open a second terminal and tail the Envoy access logs:

```bash
kubectl logs -n metal3-system -l app.kubernetes.io/name=envoy-proxy -f
```

As Ironic inspects the BMH, you'll see entries like:

```
[2026-02-19T12:00:00.000Z] "CONNECT 10.2.83.76:8000 HTTP/1.1" 200 - 256 1892 45 src=10.244.0.5:54321 dst="10.2.83.76:8000"
```

This shows:
- **CONNECT** — Ironic used HTTPS tunneling to reach the BMC
- **10.2.83.76:8000** — the mock BMC destination
- **200** — Envoy successfully tunneled the connection
- **src=10.244.0.5** — Ironic pod's IP on the pod network
- **dst=10.2.83.76:8000** — the upstream BMC that Envoy connected to

---

## Step 6 — Test Manually (Optional)

You can test the proxy independently of Ironic:

```bash
# Spin up a temporary curl pod
kubectl run proxy-test --rm -it --image=curlimages/curl -n metal3-system -- sh

# Inside the pod — test HTTP through the proxy
curl -s --proxy http://envoy-fwd-proxy-envoy:10000 \
  http://10.2.83.76:8000/redfish/v1

# Inside the pod — test HTTPS through the proxy (CONNECT tunnel)
curl -sk --proxy http://envoy-fwd-proxy-envoy:10000 \
  https://10.2.83.76:8443/redfish/v1

# Exit the test pod
exit
```

---

## Troubleshooting

### MetalLB not assigning 10.2.83.20

```bash
# Check MetalLB controller logs
kubectl logs -n metallb-system -l app=metallb,component=controller | tail -20

# Make sure the IP isn't already in use on the network
ping -c1 10.2.83.20

# Check the IPAddressPool exists
kubectl get ipaddresspool -n metallb-system
```

### Envoy pod not starting

```bash
kubectl describe pod -n metal3-system -l app.kubernetes.io/name=envoy-proxy
kubectl logs -n metal3-system -l app.kubernetes.io/name=envoy-proxy
```

### Ironic can't reach the BMC

```bash
# 1. Check proxy vars are set
kubectl exec -n metal3-system deploy/metal3-ironic -- env | grep -i proxy

# 2. Check Envoy logs for the request (or errors)
kubectl logs -n metal3-system -l app.kubernetes.io/name=envoy-proxy | tail -20

# 3. Check Envoy can reach the BMC directly
kubectl exec -n metal3-system deploy/envoy-fwd-proxy -- \
  curl -sk https://10.2.83.76:8443/redfish/v1

# 4. Check the BMH status for errors
kubectl describe bmh mock-node-1 -n metal3-system
```

### BMH stuck in "registering"

This usually means Ironic can't reach the BMC. Check:

1. Is the virtual BMC actually running on `10.2.83.76`?
   ```bash
   # From the VM host (10.2.83.181) or any machine on the network
   curl -sk https://10.2.83.76:8443/redfish/v1
   ```
2. Is the `bmc.address` in `mock-bmh.yaml` correct? (driver prefix, port, Systems path)
3. Are the credentials correct?
4. Is `disableCertificateVerification: true` set? (needed for self-signed certs)

### RBAC blocking requests (403 in Envoy logs)

If Envoy logs show `403`, the RBAC filter is blocking the destination. Check that `allowedDestinations` in `values-envoy.yaml` includes the BMC IP:

```bash
# Temporarily disable RBAC to test
helm upgrade envoy-fwd-proxy ../../ \
  -n metal3-system \
  --set fullnameOverride=envoy-fwd-proxy \
  --set envoy.auth.rbac.enabled=false
```

### NetworkPolicy blocking traffic

If Ironic gets connection timeouts to Envoy, the NetworkPolicy may be blocking:

```bash
# Check the NetworkPolicy
kubectl get networkpolicy -n metal3-system

# Temporarily disable to test
helm upgrade envoy-fwd-proxy ../../ \
  -n metal3-system \
  --set fullnameOverride=envoy-fwd-proxy \
  --set envoy.auth.networkPolicy.enabled=false
```

---

## Cleanup

```bash
# Remove the BMH
kubectl delete -f mock-bmh.yaml

# Remove the Metal3 chart
helm uninstall metal3 -n metal3-system

# Remove the Envoy proxy chart
helm uninstall envoy-fwd-proxy -n metal3-system

# Remove MetalLB pool
kubectl delete -f metallb-pool.yaml

# Remove namespace (optional)
kubectl delete namespace metal3-system
```

---

## File Reference

```
examples/dev-flat-network/
├── GUIDE.md              ← this file
├── metallb-pool.yaml     ← Step 1: MetalLB VIPs (10.2.83.20 + 10.2.83.71)
├── values-envoy.yaml     ← Step 2: Envoy proxy chart values
├── values-metal3.yaml    ← Step 3: SUSE Edge Metal3 chart values with proxy
└── mock-bmh.yaml         ← Step 4: BareMetalHost CR for the KVM guest BMC
```
