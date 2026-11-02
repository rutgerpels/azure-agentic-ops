"""Public synthetic portal; its only network destination is the private order API."""

import asyncio
import os
import time
from contextlib import asynccontextmanager, suppress
from pathlib import Path
from uuid import UUID

import httpx
from common import (
    Catalog,
    Health,
    OrderRequest,
    Receipt,
    configure_telemetry,
    dependency_event,
    protect,
)
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import ValidationError

PRIVATE_API = "http://10.42.2.4:8080"
# Option 1 VM address or the option 2 Container Apps internal ingress name; nothing else.
ALLOWED_APIS = frozenset({PRIVATE_API, "http://orderflow-api"})
STATIC = Path(__file__).parent / "static"


def create_app(transport_factory=None, probe_interval=10, timeout=4):
    base_url = os.getenv("ORDER_API_URL", PRIVATE_API)
    if base_url not in ALLOWED_APIS:
        raise ValueError("ORDER_API_URL must be one of: " + ", ".join(sorted(ALLOWED_APIS)))

    async def forward(method, path, schema, body=None, request_id=None, operation=None):
        started = time.perf_counter()
        success = False
        try:
            # A new transport/client for EVERY call forces a fresh TCP connection.
            # NSG changes do not terminate established connections.
            transport = (
                transport_factory()
                if transport_factory
                else httpx.AsyncHTTPTransport(retries=0)
            )
            async with (
                asyncio.timeout(timeout),
                httpx.AsyncClient(
                    transport=transport,
                    timeout=httpx.Timeout(timeout, connect=min(2, timeout)),
                    limits=httpx.Limits(max_connections=1, max_keepalive_connections=0),
                    follow_redirects=False,
                    trust_env=False,
                    headers={"Connection": "close", "X-OrderFlow-Request": "1"},
                ) as client,
                client.stream(method, base_url + path, json=body) as response,
            ):
                if response.status_code == 404 and path.startswith("/api/orders/"):
                    raise HTTPException(
                        404, "Receipt not found. Outcome remains unconfirmed."
                    )
                if response.status_code == 409 and method == "POST":
                    raise HTTPException(409, "Request ID belongs to another order.")
                response.raise_for_status()
                content = bytearray()
                async for chunk in response.aiter_bytes():
                    content.extend(chunk)
                    if len(content) > 32768:
                        raise ValueError("Dependency response too large")
                result = schema.model_validate_json(bytes(content)).model_dump(mode="json")
                if schema is Receipt and (
                    result["id"] != str(request_id)
                    or result["request_id"] != str(request_id)
                ):
                    raise ValueError("Receipt ID mismatch")
                success = True
                return result
        except (httpx.HTTPError, TimeoutError, ValidationError, ValueError):
            detail = (
                "Order outcome unknown. Read the receipt using the same request ID; do not retry."
                if method == "POST"
                else "Order dependency unavailable."
            )
            raise HTTPException(503, detail) from None
        finally:
            dependency_event(operation or f"api.{schema.__name__.lower()}", success,
                             started, request_id)

    async def probe():
        while True:
            with suppress(HTTPException):
                await forward("GET", "/api/health", Health, operation="api.probe")
            await asyncio.sleep(probe_interval)

    @asynccontextmanager
    async def lifespan(app):
        configure_telemetry()
        task = asyncio.create_task(probe()) if probe_interval else None
        app.state.probe_task = task
        try:
            yield
        finally:
            if task:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    protect(app)

    @app.get("/healthz")
    async def process_health():
        return {"status": "online", "scope": "portal-process-only"}

    @app.get("/api/health", response_model=Health)
    async def health():
        return await forward("GET", "/api/health", Health)

    @app.get("/api/products", response_model=Catalog)
    async def products():
        return await forward("GET", "/api/products", Catalog)

    @app.post("/api/orders", response_model=Receipt)
    async def order(body: OrderRequest):
        return await forward("POST", "/api/orders", Receipt, body.model_dump(mode="json"),
                             body.request_id)

    @app.get("/api/orders/{request_id}", response_model=Receipt)
    async def receipt(request_id: UUID):
        return await forward("GET", f"/api/orders/{request_id}", Receipt,
                             request_id=request_id)

    @app.get("/")
    async def index():
        return FileResponse(STATIC / "index.html")

    @app.get("/static/app.js")
    async def javascript():
        return FileResponse(STATIC / "app.js", media_type="text/javascript")

    @app.get("/static/styles.css")
    async def stylesheet():
        return FileResponse(STATIC / "styles.css", media_type="text/css")

    return app


app = create_app()
