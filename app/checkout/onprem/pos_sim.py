"""Store/POS traffic for Belgium and the Netherlands (standard library only).

Each country runs in its own thread, so slow Belgian checkouts never throttle
the Dutch control group.
"""

import json
import random
import threading
import time
import urllib.request

STORES = {"BE": ["BE-101", "BE-102", "BE-205", "BE-310"], "NL": ["NL-401", "NL-402", "NL-517", "NL-620"]}
SKUS = ["MILK-1L", "BREAD-800", "COFFEE-500", "APPLE-1KG", "CHEESE-400"]


def checkout(url: str, country: str) -> None:
    body = json.dumps({"country": country, "store": random.choice(STORES[country]),
                       "sku": random.choice(SKUS), "quantity": random.randint(1, 4)}).encode()
    request = urllib.request.Request(f"{url}/checkout", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=15) as response:  # noqa: S310 - fixed config URL
        response.read()


def run(url: str, country: str, interval: float) -> None:
    while True:
        started = time.monotonic()
        try:
            checkout(url, country)
        except Exception:  # noqa: BLE001 - keep simulating stores during incidents
            pass
        time.sleep(max(0.0, interval - (time.monotonic() - started)))


def main() -> None:
    with open("/etc/retailtx/pos-sim.json", encoding="utf-8") as stream:
        config = json.load(stream)
    url = config["checkoutUrl"].rstrip("/")
    if not url.startswith("https://"):
        raise ValueError("checkoutUrl must use HTTPS")
    for country in ("BE", "NL"):
        threading.Thread(target=run, args=(url, country, float(config["intervalSeconds"])),
                         daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
