"""RetailTx checkout front end (Azure App Service).

Stores call POST /checkout. Each checkout looks up the price on the simulated
on-premises backend. The per-country route is configuration: ``primary`` uses
the ERP price service, ``legacy`` uses the slow legacy validation gateway.
"""

import json
import logging
import os
import re
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from collections import deque
from pathlib import Path
from typing import Literal

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse
from opentelemetry import trace
from opentelemetry.trace import SpanKind, Status, StatusCode
from pydantic import BaseModel, Field

COUNTRIES = ("BE", "NL")
ROUTES = ("primary", "legacy")
SERVICES = {"primary": "erp-price-service", "legacy": "legacy-price-gateway"}
BACKEND_TIMEOUT_SECONDS = 5.0
STATIC = Path(__file__).resolve().parent / "static"
PAGES = {"/": ("index.html", "text/html"), "/till.css": ("till.css", "text/css"),
         "/till.js": ("till.js", "text/javascript")}
# gunicorn runs several workers; each publishes its recent checkouts to a shared temp directory.
RECENT_DIR = Path(tempfile.gettempdir()) / "retailtx-recent"
RECENT_PER_WORKER = 60
RECENT_MAX_AGE_SECONDS = 600
SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'self'; script-src 'self' https://js.monitor.azure.com; style-src 'self'; "
        "img-src 'self' data:; connect-src 'self' https://*.applicationinsights.azure.com "
        "https://*.monitor.azure.com https://js.monitor.azure.com; frame-ancestors 'none'; "
        "base-uri 'self'; form-action 'self'; object-src 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "strict-origin-when-cross-origin",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
}

if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    from azure.monitor.opentelemetry import configure_azure_monitor

    # Manual CLIENT spans below name the on-premises dependency instead of IP:port.
    configure_azure_monitor(logger_name="retailtx.checkout",
                            instrumentation_options={"urllib": {"enabled": False}})

logger = logging.getLogger("retailtx.checkout")
logger.setLevel(logging.INFO)
app = FastAPI(title="RetailTx checkout", docs_url=None, redoc_url=None, openapi_url=None)


class CheckoutRequest(BaseModel):
    country: str = Field(pattern=r"^(BE|NL)$")
    store: str = Field(pattern=r"^[A-Z]{2}-[0-9]{3}$")
    sku: str = Field(pattern=r"^[A-Z0-9-]{1,20}$")
    quantity: int = Field(ge=1, le=20)
    channel: Literal["pos", "web"] = "pos"


_recent: deque = deque(maxlen=RECENT_PER_WORKER)


def record_recent(country: str, route: str, channel: str, duration_ms: int, ok: bool) -> None:
    _recent.append({"ts": round(time.time(), 3), "country": country, "route": route,
                    "channel": channel, "ms": duration_ms, "ok": ok})
    try:
        RECENT_DIR.mkdir(exist_ok=True)
        target = RECENT_DIR / f"{os.getpid()}.json"
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(list(_recent)))
        temporary.replace(target)
    except OSError:
        pass  # the live strip is best effort; checkouts must not fail on it


def read_recent() -> list[dict]:
    entries: list[dict] = []
    cutoff = time.time() - RECENT_MAX_AGE_SECONDS
    for path in RECENT_DIR.glob("*.json") if RECENT_DIR.is_dir() else []:
        try:
            entries.extend(item for item in json.loads(path.read_text()) if item["ts"] >= cutoff)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    entries.sort(key=lambda item: item["ts"])
    return entries


def route_table() -> dict[str, str]:
    routes = {}
    for country in COUNTRIES:
        route = os.environ.get(f"PRICE_ROUTE_{country}", "primary")
        routes[country] = route if route in ROUTES else "primary"
    return routes


def backend_url(route: str) -> str:
    variable = "PRICE_LEGACY_URL" if route == "legacy" else "PRICE_PRIMARY_URL"
    value = os.environ.get(variable, "")
    if not re.fullmatch(r"http://[a-z0-9.-]+:[0-9]{2,5}", value):
        raise RuntimeError(f"{variable} is not configured")
    return value


tracer = trace.get_tracer("retailtx.checkout")


def fetch_price(route: str, url: str) -> dict:
    service = SERVICES[route]
    attributes = {"peer.service": service, "http.request.method": "GET", "url.full": url}
    with tracer.start_as_current_span(f"GET {service} /price", kind=SpanKind.CLIENT,
                                      attributes=attributes) as span:
        try:
            with urllib.request.urlopen(url, timeout=BACKEND_TIMEOUT_SECONDS) as response:  # noqa: S310 - fixed config URL
                span.set_attribute("http.response.status_code", response.status)
                return json.loads(response.read(64_000))
        except Exception as error:
            span.set_status(Status(StatusCode.ERROR, type(error).__name__))
            raise


logger.info(
    "price-route-configuration",
    extra={
        "event": "price-route-configuration",
        "routes": json.dumps(route_table()),
        "changeRef": os.environ.get("ROUTE_CHANGE_REF", "baseline"),
    },
)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "routes": route_table()}


def page(path: str) -> FileResponse:
    name, media_type = PAGES[path]
    return FileResponse(STATIC / name, media_type=media_type,
                        headers={**SECURITY_HEADERS, "Cache-Control": "no-cache"})


@app.get("/", include_in_schema=False)
def till_page() -> FileResponse:
    return page("/")


@app.get("/till.css", include_in_schema=False)
def till_css() -> FileResponse:
    return page("/till.css")


@app.get("/till.js", include_in_schema=False)
def till_js() -> FileResponse:
    return page("/till.js")


@app.get("/api/config")
def browser_config() -> dict:
    # The Application Insights connection string is designed to be public for browser telemetry.
    return {"connectionString": os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING") or None}


@app.get("/api/recent")
def recent() -> dict:
    entries = read_recent()
    return {country: [item for item in entries if item["country"] == country][-40:]
            for country in COUNTRIES}


@app.middleware("http")
async def capture_server_span(http_request: Request, call_next):
    # FastAPI adds internal endpoint spans; business attributes belong on the request (server) span.
    http_request.state.server_span = trace.get_current_span()
    return await call_next(http_request)


@app.post("/checkout")
def checkout(request: CheckoutRequest, http_request: Request) -> dict:
    route = route_table()[request.country]
    span = getattr(http_request.state, "server_span", trace.get_current_span())
    span.set_attribute("retail.country", request.country)
    span.set_attribute("retail.store", request.store)
    span.set_attribute("retail.price_route", route)
    span.set_attribute("retail.channel", request.channel)
    started = time.perf_counter()
    try:
        url = f"{backend_url(route)}/price/{request.sku}?country={request.country}"
        price = fetch_price(route, url)
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        logger.warning(
            "price-lookup-failed",
            extra={"event": "price-lookup-failed", "country": request.country, "route": route,
                   "errorType": type(error).__name__},
        )
        record_recent(request.country, route, request.channel,
                      round((time.perf_counter() - started) * 1000), ok=False)
        raise HTTPException(status_code=503, detail="Price lookup unavailable") from None
    lookup_ms = round((time.perf_counter() - started) * 1000)
    time.sleep(0.02)  # simulated payment authorisation
    total = round(float(price["unitPrice"]) * request.quantity, 2)
    record_recent(request.country, route, request.channel,
                  round((time.perf_counter() - started) * 1000), ok=True)
    return {
        "transactionId": str(uuid.uuid4()),
        "country": request.country,
        "store": request.store,
        "total": total,
        "currency": "EUR",
        "priceRoute": route,
        "priceLookupMs": lookup_ms,
    }
