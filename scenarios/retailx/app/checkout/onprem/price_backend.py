"""Simulated on-premises price services (standard library only).

``primary`` is the ERP price service (tens of milliseconds).
``legacy`` is the legacy price-validation gateway (well over a second).
"""

import argparse
import json
import random
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PROFILES = {
    "primary": {"service": "erp-price-service", "delay": (0.015, 0.045)},
    "legacy": {"service": "legacy-price-gateway", "delay": (1.4, 2.2)},
}
SKU = re.compile(r"^[A-Z0-9-]{1,20}$")


def make_handler(role: str):
    profile = PROFILES[role]

    class Handler(BaseHTTPRequestHandler):
        server_version = profile["service"]

        def log_message(self, format, *args):  # noqa: A002 - stdlib signature
            return

        def reply(self, status: int, body: dict) -> None:
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):  # noqa: N802 - stdlib signature
            url = urlparse(self.path)
            if url.path == "/health":
                return self.reply(200, {"status": "ok", "service": profile["service"]})
            parts = url.path.strip("/").split("/")
            if len(parts) != 2 or parts[0] != "price" or not SKU.fullmatch(parts[1]):
                return self.reply(404, {"error": "not found"})
            country = parse_qs(url.query).get("country", [""])[0]
            if country not in ("BE", "NL"):
                return self.reply(400, {"error": "country"})
            time.sleep(random.uniform(*profile["delay"]))
            return self.reply(200, {"sku": parts[1], "country": country,
                                    "unitPrice": 2.49, "service": profile["service"]})

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", choices=sorted(PROFILES), required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(args.role)).serve_forever()  # noqa: S104


if __name__ == "__main__":
    main()
