"""Easy Auth defense in depth and bounded single-process browser sessions."""

import base64
import json
import secrets
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from uuid import UUID

COOKIE = "__Host-retailtx-incident"
TTL = 1800


class AdmissionError(ValueError):
    def __init__(self, code, status=403):
        super().__init__(code)
        self.code, self.status = code, status


def authenticate(headers, settings):
    encoded = headers.get("x-ms-client-principal", "")
    if not encoded or len(encoded) > 16000:
        raise AdmissionError("authentication_required", 401)
    try:
        principal = json.loads(base64.b64decode(encoded, validate=True))
        if principal.get("auth_typ") != "aad":
            raise ValueError("not_aad")
        claims = principal["claims"]
        if not isinstance(claims, list) or len(claims) > 200:
            raise ValueError("invalid_claims")
        aliases = {
            "oid": {
                "oid",
                "http://schemas.microsoft.com/identity/claims/objectidentifier",
                "http://schemas.microsoft.com/identity/claims/oid",
            },
            "tid": {
                "tid",
                "http://schemas.microsoft.com/identity/claims/tenantid",
                "http://schemas.microsoft.com/identity/claims/tenantidentifier",
            },
        }
        values = {}
        for key, types in aliases.items():
            found = {str(UUID(c["val"])) for c in claims if c.get("typ") in types}
            if len(found) != 1:
                raise ValueError("missing_or_conflicting_claim")
            values[key] = found.pop()
        if values["oid"] != settings.operator or values["tid"] != settings.tenant:
            raise ValueError("principal_not_allowed")
        return values["oid"]
    except (ValueError, KeyError, TypeError, AttributeError):
        raise AdmissionError("principal_not_allowed") from None


def check_request(headers, scheme, settings, method):
    if scheme != "https" or headers.get("host", "").lower() != settings.hostname:
        raise AdmissionError("invalid_host_or_scheme")
    if headers.get("sec-fetch-site") not in (None, "same-origin", "none"):
        raise AdmissionError("cross_site_request")
    if method not in ("GET", "POST"):
        raise AdmissionError("method_not_allowed", 405)
    if method == "POST":
        if headers.get("origin") != f"https://{settings.hostname}":
            raise AdmissionError("invalid_origin")
        if headers.get("content-type", "").split(";")[0].strip().lower() != "application/json":
            raise AdmissionError("json_required", 415)


@dataclass
class Session:
    principal: str
    csrf: str
    expires: float
    scope: list = field(default_factory=lambda: ["BE", "NL"])
    fixture: str = "healthy"
    history: list = field(default_factory=list)
    turns: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)


class SessionStore:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.sessions = {}
        self.rates = {}
        self.chat_rates = {}
        self.lock = threading.Lock()
        self.agent_slots = threading.BoundedSemaphore(2)

    def admit(self, principal):
        with self.lock:
            now = self.clock()
            times = self.rates.setdefault(principal, deque())
            while times and now - times[0] >= 60:
                times.popleft()
            if len(times) >= 90:
                raise AdmissionError("rate_limited", 429)
            times.append(now)
            for sid in list(self.sessions):
                if self.sessions[sid].expires <= now:
                    del self.sessions[sid]

    def create(self, principal):
        with self.lock:
            now = self.clock()
            for sid in list(self.sessions):
                if self.sessions[sid].expires <= now:
                    del self.sessions[sid]
            if (
                len(self.sessions) >= 32
                or sum(s.principal == principal for s in self.sessions.values()) >= 8
            ):
                raise AdmissionError("session_limit", 429)
            sid = secrets.token_urlsafe(32)
            session = Session(principal, secrets.token_urlsafe(32), now + TTL)
            self.sessions[sid] = session
            return sid, session

    def admit_chat(self, principal):
        with self.lock:
            now = self.clock()
            times = self.chat_rates.setdefault(principal, deque())
            while times and now - times[0] >= 60:
                times.popleft()
            if len(times) >= 6:
                raise AdmissionError("chat_rate_limited", 429)
            times.append(now)

    def get(self, sid, principal, csrf=None):
        with self.lock:
            session = self.sessions.get(sid or "")
            if session is None or session.expires <= self.clock() or session.principal != principal:
                raise AdmissionError("session_expired", 401)
            if csrf is not None and not secrets.compare_digest(session.csrf, csrf):
                raise AdmissionError("invalid_csrf")
            return session

    def reset(self, sid, principal, csrf):
        self.get(sid, principal, csrf)
        with self.lock:
            self.sessions.pop(sid, None)
