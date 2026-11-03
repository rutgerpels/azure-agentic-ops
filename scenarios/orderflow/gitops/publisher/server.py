"""Stateless Streamable HTTP MCP subset, with no arbitrary read or write proxy."""

import asyncio
import hmac
import json
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .config import MAX_REQUEST, PROTOCOLS, Settings
from .github import GitHub
from .receipts import BlobReceipts
from .service import FindInput, Publisher, PublishInput

TOOLS = [
    {
        "name": "find_incident_issue",
        "description": (
            "Observe the fixed repository for an incident; unknown never permits replay."
        ),
        "inputSchema": FindInput.model_json_schema(),
        "annotations": {"readOnlyHint": True, "openWorldHint": True},
    },
    {
        "name": "publish_incident_issue",
        "description": (
            "Create one orderflow-incident issue only after native human approval. "
            "incident_key must equal ORDERFLOW_GENERATION, the configured owner GUID. "
            "Unknown means observe, never retry creation."
        ),
        "inputSchema": PublishInput.model_json_schema(),
        "annotations": {
            "readOnlyHint": False, "destructiveHint": False,
            "idempotentHint": True, "openWorldHint": True,
        },
    },
]


def rpc_error(request_id: Any, code: int, message: str, status: int = 200) -> JSONResponse:
    return JSONResponse(
        {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}},
        status_code=status,
    )


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON member")
        result[key] = value
    return result


def _invalid_constant(value: str) -> None:
    raise ValueError("Non-JSON numeric constant")


def create_app(settings: Settings, publisher: Publisher, lifespan: Any = None) -> FastAPI:
    app = FastAPI(
        docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan,
        redirect_slashes=False,
    )
    if settings.public_origin:
        app.add_middleware(
            TrustedHostMiddleware, allowed_hosts=[urlsplit(settings.public_origin).hostname],
        )

    @app.middleware("http")
    async def guard(request: Request, call_next: Any) -> Response:
        # Compare bytes so malformed non-ASCII credentials also fail without a timing shortcut.
        if request.url.path != "/healthz":
            keys = request.headers.getlist("x-orderflow-key")
            supplied = keys[0] if len(keys) == 1 else ""
            if not hmac.compare_digest(supplied.encode(), settings.inbound_key.encode()):
                return JSONResponse({"error": "Unauthorized"}, status_code=401)
        origin = request.headers.getlist("origin")
        if origin and (not settings.public_origin or origin != [settings.public_origin]):
            return JSONResponse({"error": "Origin forbidden"}, status_code=403)
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.get("/healthz")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.api_route("/mcp", methods=["GET", "DELETE"])
    def unsupported_stream() -> Response:
        return Response(status_code=405, headers={"Allow": "POST"})

    @app.post("/mcp")
    async def mcp(request: Request) -> Response:
        version = request.headers.get("mcp-protocol-version", "2025-03-26")
        if version not in PROTOCOLS:
            return rpc_error(None, -32600, "Unsupported MCP protocol version", 400)
        if request.headers.get("content-type", "").split(";")[0].strip() != "application/json":
            return Response(status_code=415)
        accepted = {
            part.split(";")[0].strip() for part in request.headers.get("accept", "").split(",")
        }
        if not {"application/json", "text/event-stream"}.issubset(accepted):
            return Response(status_code=406)
        data = bytearray()

        async def read_bounded() -> None:
            async for chunk in request.stream():
                if len(data) + len(chunk) > MAX_REQUEST:
                    raise OverflowError
                data.extend(chunk)

        try:
            await asyncio.wait_for(read_bounded(), timeout=10)
        except OverflowError:
            return Response(status_code=413)
        except TimeoutError:
            return Response(status_code=408)
        try:
            message = json.loads(
                data, object_pairs_hook=_unique_object, parse_constant=_invalid_constant,
            )
        except (ValueError, RecursionError):
            return rpc_error(None, -32700, "Parse error", 400)
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return rpc_error(None, -32600, "Invalid Request", 400)
        request_id = message.get("id")
        if (
            "id" in message and type(request_id) not in (str, int)
            or not isinstance(message.get("method"), str)
            or set(message) - {"jsonrpc", "id", "method", "params"}
        ):
            return rpc_error(None, -32600, "Invalid Request", 400)
        method = message["method"]
        params = message.get("params", {})
        if not isinstance(params, dict):
            return rpc_error(request_id, -32602, "Invalid params", 400)
        if "id" not in message:
            if (
                method == "notifications/initialized"
                and not (set(params) - {"_meta"})
                and ("_meta" not in params or isinstance(params["_meta"], dict))
            ):
                return Response(status_code=202)
            return Response(status_code=400)
        result: dict[str, Any]
        if method == "initialize":
            if (
                not isinstance(params.get("protocolVersion"), str)
                or not isinstance(params.get("capabilities"), dict)
                or not isinstance(params.get("clientInfo"), dict)
            ):
                return rpc_error(request_id, -32602, "Invalid params")
            requested = params["protocolVersion"]
            result = {
                "protocolVersion": requested if requested in PROTOCOLS else PROTOCOLS[-1],
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "orderflow-issue-publisher", "version": "1.0.0"},
            }
        elif (
            method == "ping" and not (set(params) - {"_meta"})
            and ("_meta" not in params or isinstance(params["_meta"], dict))
        ):
            result = {}
        elif (
            method == "tools/list" and not (set(params) - {"_meta"})
            and ("_meta" not in params or isinstance(params["_meta"], dict))
        ):
            result = {"tools": TOOLS}
        elif method == "tools/call":
            if (
                set(params) - {"name", "arguments", "_meta"}
                or "_meta" in params and not isinstance(params["_meta"], dict)
            ):
                return rpc_error(request_id, -32602, "Invalid params")
            name, arguments = params.get("name"), params.get("arguments", {})
            if name not in ("find_incident_issue", "publish_incident_issue"):
                return rpc_error(request_id, -32602, "Unknown tool")
            try:
                if name == "find_incident_issue":
                    inputs = FindInput.model_validate(arguments)
                else:
                    inputs = PublishInput.model_validate(arguments)
            except ValidationError:
                # Pydantic error details contain caller-supplied issue text; never return/log them.
                return rpc_error(request_id, -32602, "Invalid tool arguments")
            if inputs.incident_key != settings.generation:
                return rpc_error(request_id, -32602, "Incident key must match owner generation")
            if isinstance(inputs, PublishInput):
                outcome = await run_in_threadpool(publisher.publish, inputs)
            else:
                outcome = await run_in_threadpool(publisher.find, inputs)
            result = {
                "content": [{"type": "text", "text": json.dumps(outcome, separators=(",", ":"))}],
                "isError": outcome["status"] == "unknown",
            }
        elif method in ("tools/list", "ping"):
            return rpc_error(request_id, -32602, "Invalid params")
        else:
            return rpc_error(request_id, -32601, "Method not found")
        return JSONResponse({"jsonrpc": "2.0", "id": request_id, "result": result})

    return app


def create_runtime_app() -> FastAPI:
    settings = Settings.from_env()
    client = httpx.Client(
        transport=httpx.HTTPTransport(retries=0, trust_env=False),
        follow_redirects=False, trust_env=False,
        limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
    )
    receipts = BlobReceipts(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> Any:
        try:
            yield
        finally:
            client.close()
            receipts.close()

    return create_app(settings, Publisher(GitHub(settings, client), receipts), lifespan)
