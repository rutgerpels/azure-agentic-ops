"""Small shared wire contract and HTTP guardrails for the synthetic demo."""

import asyncio
import logging
import os
import time
from collections import deque
from typing import Literal
from urllib.parse import urlsplit
from uuid import UUID

from fastapi.exceptions import RequestValidationError
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field
from starlette.datastructures import Headers
from starlette.responses import JSONResponse

ProductId = Literal["field-kit", "sensor-pack", "gateway"]


class OrderRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    product_id: ProductId
    quantity: int = Field(strict=True, ge=1, le=5)
    request_id: UUID


class Product(BaseModel):
    id: ProductId
    category: Literal["equipment"]
    name: str = Field(max_length=80)
    description: str = Field(max_length=200)
    price_cents: int = Field(strict=True, ge=0)


class Catalog(BaseModel):
    products: list[Product] = Field(min_length=3, max_length=3)


class Receipt(BaseModel):
    id: UUID
    request_id: UUID
    product_id: ProductId
    quantity: int = Field(strict=True, ge=1, le=5)
    total_cents: int = Field(strict=True, ge=0)
    created_at: AwareDatetime
    status: Literal["confirmed"] = "confirmed"
    synthetic: Literal[True] = True


class Health(BaseModel):
    status: Literal["healthy"]
    dependency: Literal["cosmos"]


def configure_telemetry():
    logger = logging.getLogger("orderflow")
    logger.setLevel(logging.INFO)
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter(
            "%(message)s operation=%(operation)s success=%(success)s "
            "duration_ms=%(duration_ms)s request_id=%(request_id)s"
        ))
        logger.addHandler(handler)
    if os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING"):
        from azure.monitor.opentelemetry import configure_azure_monitor

        configure_azure_monitor(logger_name="orderflow")


def dependency_event(operation, success, started, request_id=None):
    fields = {
        "operation": operation,
        "success": str(success).lower(),
        "duration_ms": round((time.perf_counter() - started) * 1000, 1),
        "request_id": str(request_id) if request_id else "",
    }
    logging.getLogger("orderflow").info("orderflow_dependency", extra=fields)


async def invalid_request(_request, _error):
    return JSONResponse({"detail": "Invalid request."}, status_code=422)


def protect(app):
    app.add_middleware(GuardMiddleware)
    app.add_exception_handler(RequestValidationError, invalid_request)


class GuardMiddleware:
    """Bound bodies and request volume without trusting Content-Length."""

    def __init__(self, app):
        self.app = app
        self.requests = deque()
        self.posts = deque()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        async def secured_send(message):
            if message["type"] == "http.response.start":
                headers = list(message.get("headers", []))
                headers.extend(
                    (key.encode(), value.encode())
                    for key, value in {
                        "cache-control": "no-store",
                        "x-content-type-options": "nosniff",
                        "x-frame-options": "DENY",
                        "referrer-policy": "no-referrer",
                        "permissions-policy": "camera=(), microphone=(), geolocation=()",
                        "strict-transport-security": "max-age=31536000",
                        "content-security-policy": (
                            "default-src 'none'; script-src 'self'; style-src 'self'; "
                            "connect-src 'self'; img-src 'self'; base-uri 'none'; "
                            "form-action 'self'; frame-ancestors 'none'"
                        ),
                    }.items()
                )
                message["headers"] = headers
            await send(message)

        async def refuse(status, detail):
            await JSONResponse({"detail": detail}, status_code=status)(
                scope, receive, secured_send
            )

        if scope["path"].startswith("/api/"):
            now = time.monotonic()
            for queue in (self.requests, self.posts):
                while queue and queue[0] <= now - 60:
                    queue.popleft()
            if len(self.requests) >= 180 or (
                scope["method"] == "POST" and len(self.posts) >= 20
            ):
                return await refuse(429, "Demo request limit reached. Wait one minute.")
            self.requests.append(now)
            if scope["method"] == "POST":
                self.posts.append(now)

        if scope["method"] == "POST":
            headers = Headers(scope=scope)
            origin = headers.get("origin")
            if (
                headers.get("x-orderflow-request") != "1"
                or headers.get("sec-fetch-site") not in (None, "same-origin", "none")
                or (origin and urlsplit(origin).netloc != headers.get("host"))
            ):
                return await refuse(403, "Same-origin requests only.")
            if headers.get("content-type", "").split(";")[0] != "application/json":
                return await refuse(415, "JSON required.")
            body = bytearray()
            try:
                async with asyncio.timeout(4):
                    while True:
                        chunk = await receive()
                        if chunk["type"] == "http.disconnect":
                            return
                        body.extend(chunk.get("body", b""))
                        if len(body) > 1024:
                            return await refuse(413, "Request too large.")
                        if not chunk.get("more_body", False):
                            break
            except TimeoutError:
                return await refuse(408, "Request body timed out.")
            delivered = False

            async def buffered_receive():
                nonlocal delivered
                if not delivered:
                    delivered = True
                    return {"type": "http.request", "body": bytes(body), "more_body": False}
                return await receive()

            return await self.app(scope, buffered_receive, secured_send)
        return await self.app(scope, receive, secured_send)
