"""Single-worker App Service entry point; only exact GET liveness is anonymous."""

import asyncio
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from agent import AgentError, FoundryAgent
from config import Settings, managed_identity_credential
from evidence import COUNTRIES, STATES, EvidenceService
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse
from security import COOKIE, TTL, AdmissionError, SessionStore, authenticate, check_request
from starlette.concurrency import run_in_threadpool
from telemetry import configure, event

STATIC = Path(__file__).parent / "static"
HEADERS = {
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; "
    "img-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; "
    "object-src 'none'; form-action 'self'; upgrade-insecure-requests",
    "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=()",
    "Cache-Control": "no-store",
}


def error_response(code, status, trace_id):
    return JSONResponse({"error": code, "traceId": trace_id}, status_code=status, headers=HEADERS)


class Guard:
    def __init__(self, app, state):
        self.app, self.state = app, state

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        if scope["method"] == "GET" and scope["path"] == "/health/live":
            return await self.app(scope, receive, send)
        trace_id = uuid.uuid4().hex
        try:
            # Reject duplicate security headers instead of accepting parser-dependent values.
            raw = scope["headers"]
            keys = [
                key
                for key, _ in raw
                if key
                in (
                    b"host",
                    b"origin",
                    b"x-ms-client-principal",
                    b"x-csrf-token",
                    b"content-length",
                )
            ]
            if len(keys) != len(set(keys)):
                raise AdmissionError("duplicate_security_header")
            headers = {k.decode("latin1"): v.decode("latin1") for k, v in raw}
            settings = self.state.settings
            check_request(headers, scope["scheme"], settings, scope["method"])
            principal = authenticate(headers, settings)
            self.state.sessions.admit(principal)
            scope.setdefault("state", {}).update(principal=principal, trace_id=trace_id)
            if scope["method"] == "POST":
                length = headers.get("content-length")
                if length is not None and (not length.isdigit() or int(length) > 4096):
                    raise AdmissionError("request_too_large", 413)
                chunks, size = [], 0

                async def collect():
                    nonlocal size
                    while True:
                        part = await receive()
                        if part["type"] == "http.disconnect":
                            raise AdmissionError("request_disconnected", 400)
                        size += len(part.get("body", b""))
                        if size > 4096:
                            raise AdmissionError("request_too_large", 413)
                        chunks.append(part.get("body", b""))
                        if not part.get("more_body", False):
                            break

                await asyncio.wait_for(collect(), timeout=5)
                body = b"".join(chunks)
                sent = False
                original_receive = receive

                async def replay():
                    nonlocal sent
                    if not sent:
                        sent = True
                        return {"type": "http.request", "body": body, "more_body": False}
                    return await original_receive()

                receive = replay

            async def secured_send(message):
                if message["type"] == "http.response.start":
                    existing = list(message.get("headers", []))
                    existing_keys = {k.lower() for k, _ in existing}
                    existing.extend(
                        (k.lower().encode(), v.encode())
                        for k, v in HEADERS.items()
                        if k.lower().encode() not in existing_keys
                    )
                    existing.append((b"x-trace-id", trace_id.encode()))
                    message["headers"] = existing
                await send(message)

            await self.app(scope, receive, secured_send)
        except AdmissionError as error:
            event("request_rejected", errorType=error.code, traceId=trace_id)
            await error_response(error.code, error.status, trace_id)(scope, receive, send)
        except TimeoutError:
            await error_response("request_timeout", 408, trace_id)(scope, receive, send)


def create_app(settings=None, agent=None, sessions=None):
    @asynccontextmanager
    async def lifespan(instance):
        configure()
        instance.state.settings = settings or Settings.from_env(allow_unpinned=True)
        instance.state.sessions = sessions or SessionStore()
        credential = None
        instance.state.agent = agent
        if agent is None and instance.state.settings.agent_version:
            credential = managed_identity_credential()
            instance.state.agent = FoundryAgent(
                instance.state.settings, EvidenceService(instance.state.settings, credential)
            )
        event(
            "application_ready",
            evidenceMode=instance.state.settings.mode,
            agentConfigured=bool(instance.state.agent),
        )
        yield
        if agent is None and instance.state.agent is not None:
            instance.state.agent.close()
            credential.close()
        instance.state.sessions.sessions.clear()

    instance = FastAPI(
        title="RetailTx incident assistant",
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    instance.add_middleware(Guard, state=instance.state)
    # Parent/cloud tests can inspect this only in-process; it is never an HTTP admin surface.
    if settings:
        instance.state.settings = settings
    instance.state.sessions = sessions or SessionStore()

    @instance.exception_handler(AdmissionError)
    async def admission_error(request, error):
        return error_response(error.code, error.status, request.state.trace_id)

    @instance.exception_handler(Exception)
    async def unexpected_error(request, error):
        event("request_error", errorType=type(error).__name__, traceId=request.state.trace_id)
        return error_response("internal_error", 500, request.state.trace_id)

    def session_for(request, mutate=False):
        csrf = request.headers.get("x-csrf-token", "") if mutate else None
        return instance.state.sessions.get(
            request.cookies.get(COOKIE), request.state.principal, csrf=csrf
        )

    async def payload(request, fields):
        try:
            data = await request.json()
        except (ValueError, UnicodeDecodeError):
            raise AdmissionError("invalid_json", 400) from None
        if type(data) is not dict or set(data) != set(fields):
            raise AdmissionError("invalid_request_fields", 400)
        return data

    def describe(session):
        return {
            "csrfToken": session.csrf,
            "scope": session.scope,
            "turns": session.turns,
            "fixtureState": session.fixture,
            "fixtureStates": list(STATES),
            "evidenceMode": instance.state.settings.mode,
            "maxTurns": 8,
            "agentConfigured": instance.state.agent is not None,
            "notice": "Read-only assistant. Store context is synthetic. No remediation tools.",
        }

    @instance.get("/health/live")
    async def liveness():
        return JSONResponse({"status": "ok"}, headers=HEADERS)

    @instance.get("/")
    def index():
        return FileResponse(STATIC / "index.html", media_type="text/html")

    @instance.get("/incident.css")
    def css():
        return FileResponse(STATIC / "incident.css", media_type="text/css")

    @instance.get("/incident.js")
    def javascript():
        return FileResponse(STATIC / "incident.js", media_type="text/javascript")

    @instance.get("/api/session")
    def browser_session(request: Request):
        sid = request.cookies.get(COOKIE)
        if sid:
            try:
                return describe(session_for(request))
            except AdmissionError as error:
                if error.status != 401:
                    raise
        sid, session = instance.state.sessions.create(request.state.principal)
        response = JSONResponse(describe(session))
        response.set_cookie(
            COOKIE, sid, secure=True, httponly=True, samesite="strict", max_age=TTL, path="/"
        )
        return response

    @instance.post("/api/settings")
    async def browser_settings(request: Request):
        session = session_for(request, True)
        data = await payload(request, ("countries", "fixtureState"))
        countries = data["countries"]
        if (
            type(countries) is not list
            or not 1 <= len(countries) <= 2
            or any(type(c) is not str or c not in COUNTRIES for c in countries)
            or len(set(countries)) != len(countries)
            or type(data["fixtureState"]) is not str
            or data["fixtureState"] not in STATES
        ):
            raise AdmissionError("invalid_settings", 400)
        if instance.state.settings.mode == "live" and data["fixtureState"] != session.fixture:
            raise AdmissionError("fixture_control_disabled_in_live_mode", 400)
        if not session.lock.acquire(blocking=False):
            raise AdmissionError("conversation_busy", 409)
        try:
            session_for(request, True)
            if session.scope != sorted(countries):
                session.history.clear()
                session.turns = 0
            session.scope = sorted(countries)
            session.fixture = data["fixtureState"]
            return describe(session)
        finally:
            session.lock.release()

    @instance.post("/api/reset")
    async def reset(request: Request):
        session = session_for(request, True)
        await payload(request, ())
        if not session.lock.acquire(blocking=False):
            raise AdmissionError("conversation_busy", 409)
        try:
            instance.state.sessions.reset(
                request.cookies.get(COOKIE),
                request.state.principal,
                request.headers.get("x-csrf-token", ""),
            )
            response = JSONResponse({"reset": True})
            response.delete_cookie(COOKIE, path="/", secure=True, httponly=True, samesite="strict")
            return response
        finally:
            session.lock.release()

    def perform_turn(request, session, message):
        # The worker thread owns every inference lock. Client disconnect/cancellation
        # cannot release a slot while a bounded SDK request is still running.
        if instance.state.agent is None:
            return error_response("agent_not_configured", 503, request.state.trace_id)
        if not session.lock.acquire(blocking=False):
            raise AdmissionError("conversation_busy", 409)
        try:
            session_for(request, True)
        except AdmissionError:
            session.lock.release()
            raise
        # Acquire per-principal guard as well as per-conversation guard; separate tabs
        # must not multiply Foundry concurrency for the same identity.
        store = instance.state.sessions
        with store.lock:
            busy = getattr(store, "busy", set())
            store.busy = busy
            already_busy = session.principal in busy
            if not already_busy:
                busy.add(session.principal)
        if already_busy:
            session.lock.release()
            raise AdmissionError("principal_busy", 429)
        try:
            if session.turns >= 8:
                raise AdmissionError("turn_limit_reset_required", 429)
            store.admit_chat(session.principal)
            if not store.agent_slots.acquire(blocking=False):
                raise AdmissionError("agent_busy", 429)
            try:
                # Keep lock held until the bounded synchronous SDK loop actually finishes.
                result = instance.state.agent.turn(
                    list(session.history), message.strip(), list(session.scope), session.fixture
                )
            except AgentError as error:
                return error_response(error.code, 502, request.state.trace_id)
            finally:
                store.agent_slots.release()
            # A guardrail-blocked request must not be replayed, or every later turn re-blocks.
            if not result.get("contentFiltered"):
                session.history.extend(
                    [
                        {"role": "user", "content": message.strip()},
                        {"role": "assistant", "content": result["answer"]},
                    ]
                )
                session.history = session.history[-12:]
            session.turns += 1
            event(
                "agent_turn_completed",
                traceId=request.state.trace_id,
                toolCount=len(result["tools"]),
                evidenceMode=instance.state.settings.mode,
            )
            return result
        finally:
            with store.lock:
                store.busy.discard(session.principal)
            session.lock.release()

    @instance.post("/api/chat")
    async def chat(request: Request):
        session = session_for(request, True)
        data = await payload(request, ("message",))
        message = data["message"]
        if (
            type(message) is not str
            or not 1 <= len(message.strip()) <= 2000
            or any(ord(char) < 32 and char not in "\r\n\t" for char in message)
        ):
            raise AdmissionError("invalid_message", 400)
        return await run_in_threadpool(perform_turn, request, session, message)

    return instance


app = create_app()
