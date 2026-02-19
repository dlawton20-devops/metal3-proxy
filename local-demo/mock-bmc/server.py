#!/usr/bin/env python3
"""
Mock BMC Redfish server.

Simulates a Baseboard Management Controller exposing a Redfish API
on HTTP (:8000) and HTTPS (:8443) with a self-signed certificate.
"""

import json
import ssl
import subprocess
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# ── Redfish mock data ──────────────────────────────────────────────────────────

SERVICE_ROOT = {
    "@odata.type": "#ServiceRoot.v1_15_0.ServiceRoot",
    "@odata.id": "/redfish/v1",
    "Id": "RootService",
    "Name": "Mock BMC Root Service",
    "RedfishVersion": "1.15.0",
    "UUID": "00000000-0000-0000-0000-000000000001",
    "Systems": {"@odata.id": "/redfish/v1/Systems"},
    "Managers": {"@odata.id": "/redfish/v1/Managers"},
}

SYSTEMS_COLLECTION = {
    "@odata.type": "#ComputerSystemCollection.ComputerSystemCollection",
    "@odata.id": "/redfish/v1/Systems",
    "Name": "Computer System Collection",
    "Members@odata.count": 1,
    "Members": [{"@odata.id": "/redfish/v1/Systems/1"}],
}

SYSTEM_1 = {
    "@odata.type": "#ComputerSystem.v1_20_0.ComputerSystem",
    "@odata.id": "/redfish/v1/Systems/1",
    "Id": "1",
    "Name": "Mock Bare Metal Server",
    "Manufacturer": "MockVendor",
    "Model": "PowerEdge Mock",
    "SerialNumber": "MOCK-SN-001",
    "UUID": "4c4c4544-004a-4d10-804b-b4c04f333031",
    "PowerState": "On",
    "Status": {"State": "Enabled", "Health": "OK"},
    "Boot": {
        "BootSourceOverrideEnabled": "Once",
        "BootSourceOverrideTarget": "Pxe",
        "BootSourceOverrideTarget@Redfish.AllowableValues": [
            "None", "Pxe", "Cd", "Hdd", "BiosSetup",
        ],
    },
    "ProcessorSummary": {"Count": 2, "Model": "Intel Xeon Mock"},
    "MemorySummary": {"TotalSystemMemoryGiB": 128},
    "Actions": {
        "#ComputerSystem.Reset": {
            "target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
            "ResetType@Redfish.AllowableValues": [
                "On", "ForceOff", "GracefulShutdown", "GracefulRestart", "ForceRestart",
            ],
        }
    },
}

MANAGERS_COLLECTION = {
    "@odata.type": "#ManagerCollection.ManagerCollection",
    "@odata.id": "/redfish/v1/Managers",
    "Name": "Manager Collection",
    "Members@odata.count": 1,
    "Members": [{"@odata.id": "/redfish/v1/Managers/1"}],
}

MANAGER_1 = {
    "@odata.type": "#Manager.v1_17_0.Manager",
    "@odata.id": "/redfish/v1/Managers/1",
    "Id": "1",
    "Name": "Manager",
    "ManagerType": "BMC",
    "FirmwareVersion": "1.00.00",
    "Status": {"State": "Enabled", "Health": "OK"},
}

ROUTES = {
    "/redfish/v1": SERVICE_ROOT,
    "/redfish/v1/": SERVICE_ROOT,
    "/redfish/v1/Systems": SYSTEMS_COLLECTION,
    "/redfish/v1/Systems/": SYSTEMS_COLLECTION,
    "/redfish/v1/Systems/1": SYSTEM_1,
    "/redfish/v1/Systems/1/": SYSTEM_1,
    "/redfish/v1/Managers": MANAGERS_COLLECTION,
    "/redfish/v1/Managers/": MANAGERS_COLLECTION,
    "/redfish/v1/Managers/1": MANAGER_1,
    "/redfish/v1/Managers/1/": MANAGER_1,
}

POWER_STATE = {"state": "On"}


# ── Handler ────────────────────────────────────────────────────────────────────

class RedfishHandler(BaseHTTPRequestHandler):
    server_version = "MockBMC/1.0"

    def _send_json(self, code, body):
        payload = json.dumps(body, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("OData-Version", "4.0")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path in ROUTES:
            # Inject live power state into System response
            body = ROUTES[self.path]
            if self.path.rstrip("/") == "/redfish/v1/Systems/1":
                body = {**body, "PowerState": POWER_STATE["state"]}
            self._send_json(200, body)
        else:
            self._send_json(404, {
                "error": {
                    "code": "Base.1.0.GeneralError",
                    "message": f"Resource {self.path} not found",
                }
            })

    def do_POST(self):
        path = self.path.rstrip("/")
        if path == "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset":
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            reset_type = body.get("ResetType", "On")

            if reset_type in ("ForceOff", "GracefulShutdown"):
                POWER_STATE["state"] = "Off"
            else:
                POWER_STATE["state"] = "On"

            print(f"[BMC] Reset action: {reset_type} → PowerState={POWER_STATE['state']}")
            self._send_json(200, {"Message": f"Reset {reset_type} accepted"})
        else:
            self._send_json(404, {
                "error": {
                    "code": "Base.1.0.GeneralError",
                    "message": f"Action {self.path} not found",
                }
            })

    def log_message(self, fmt, *args):
        print(f"[BMC] {self.address_string()} - {fmt % args}")


# ── TLS cert generation ───────────────────────────────────────────────────────

def generate_self_signed_cert(cert_dir="/tmp/certs"):
    Path(cert_dir).mkdir(parents=True, exist_ok=True)
    cert_file = f"{cert_dir}/bmc.crt"
    key_file = f"{cert_dir}/bmc.key"

    if not Path(cert_file).exists():
        print("[BMC] Generating self-signed TLS certificate…")
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", key_file, "-out", cert_file,
            "-days", "365", "-nodes",
            "-subj", "/CN=mock-bmc/O=MockVendor",
            "-addext", "subjectAltName=DNS:mock-bmc,DNS:localhost,IP:127.0.0.1",
        ], check=True, capture_output=True)
        print("[BMC] Certificate generated.")

    return cert_file, key_file


# ── Main ───────────────────────────────────────────────────────────────────────

def run_server(port, ssl_context=None, label="HTTP"):
    server = HTTPServer(("0.0.0.0", port), RedfishHandler)
    if ssl_context:
        server.socket = ssl_context.wrap_socket(server.socket, server_side=True)
    print(f"[BMC] {label} server listening on :{port}")
    server.serve_forever()


def main():
    # HTTP server
    http_thread = threading.Thread(
        target=run_server, args=(8000,), kwargs={"label": "HTTP"}, daemon=True,
    )
    http_thread.start()

    # HTTPS server
    cert_file, key_file = generate_self_signed_cert()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert_file, key_file)

    run_server(8443, ssl_context=ctx, label="HTTPS")


if __name__ == "__main__":
    main()
