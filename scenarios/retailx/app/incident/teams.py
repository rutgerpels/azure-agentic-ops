"""Personal Teams admission and bounded, no-replay receipts on owned App Service storage."""

import hashlib
import json
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit
from uuid import UUID, uuid4

from evidence import STATES

HELP = (
    "Read-only Retailx pilot. All checkout evidence is synthetic; no infrastructure actions. "
    "Ask about BE/NL checkout impact or store opening hours. "
    "Commands: /fixture healthy|interrupted|recovering|stale|unavailable, /reset, /status, /help. "
    "Follow-up questions fetch new evidence. A healthy fixture does not prove real recovery."
)
FIXTURES = frozenset(STATES) & {"healthy", "interrupted", "recovering", "stale", "unavailable"}
LOCK_SECONDS = 240
TTL = 1800


class TeamsError(ValueError):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.code, self.status = code, status


@dataclass(frozen=True)
class TeamsSettings:
    client_id: str
    tenant: str
    operator: str
    directory: Path

    @classmethod
    def from_env(cls, settings):
        if settings.mode != "fixture":
            raise TeamsError("teams_pilot_requires_fixture_mode")
        client = str(UUID(os.environ["TEAMS_BOT_CLIENT_ID"]))
        user = str(UUID(os.environ["TEAMS_ALLOWED_OBJECT_ID"]))
        namespace = hashlib.sha256(f"{settings.owner}:{settings.run}".encode()).hexdigest()
        return cls(client, settings.tenant, user, Path("/home/data/incident/teams") / namespace)


@dataclass(frozen=True)
class Message:
    conversation: str
    operation: str
    text: str


def admit(activity, settings, now=None):
    """Call only after SDK JWT verification; Teams supplies user/tenant activity fields."""
    try:
        conversation = activity["conversation"]
        tenant = str(UUID(activity["channelData"]["tenant"]["id"]))
        user = str(UUID(activity["from"]["aadObjectId"]))
        recipient = activity["recipient"]["id"]
        timestamp = datetime.fromisoformat(activity["timestamp"].replace("Z", "+00:00"))
        age = (time.time() if now is None else now) - timestamp.timestamp()
        service = urlsplit(activity["serviceUrl"])
        attachments = activity.get("attachments")
        if attachments is None:
            attachments = []
        text_presentation_only = isinstance(attachments, list) and len(attachments) <= 1
        for item in attachments if text_presentation_only else []:
            text_presentation_only = (
                isinstance(item, dict)
                and set(item) <= {"contentType", "content"}
                and item.get("contentType") == "text/html"
                and isinstance(item.get("content"), str)
                and len(item["content"]) <= 16000
            )
        if (
            activity["type"] != "message"
            or activity["channelId"] != "msteams"
            or conversation["conversationType"] != "personal"
            or tenant != settings.tenant
            or user != settings.operator
            or conversation.get("tenantId", tenant).lower() != tenant
            or recipient != f"28:{settings.client_id}"
            or activity["recipient"].get("role") not in (None, "bot")
            or activity["from"].get("role") not in (None, "user")
            or timestamp.utcoffset() is None
            or not -60 <= age <= 600
            or service.scheme != "https"
            or service.hostname not in ("smba.trafficmanager.net", "smba.infra.teams.microsoft.com")
            or service.port not in (None, 443)
            or service.username
            or service.password
            or service.query
            or service.fragment
            or not re.fullmatch(r"/[A-Za-z0-9/_-]{0,200}", service.path)
            or not text_presentation_only
            or activity.get("value") is not None
        ):
            raise TeamsError("teams_activity_not_allowed", 403)
        text = activity["text"]
        if (
            type(text) is not str
            or not 1 <= len(text.strip()) <= 2000
            or any(ord(char) < 32 and char not in "\n\r\t" for char in text)
        ):
            raise TeamsError("invalid_message")
        identifiers = (conversation["id"], activity["id"])
        if any(type(value) is not str or not 1 <= len(value) <= 512 for value in identifiers):
            raise TeamsError("invalid_activity_identifier")
        scope = f"{tenant}:{user}:{identifiers[0]}"
        key = hashlib.sha256(scope.encode()).hexdigest()
        operation = hashlib.sha256(f"{scope}:{identifiers[1]}".encode()).hexdigest()
        return Message(key, operation, text.strip())
    except (KeyError, TypeError, AttributeError, ValueError) as error:
        if isinstance(error, TeamsError):
            raise
        raise TeamsError("invalid_teams_activity") from None


class ReceiptStore:
    """One instance/worker only. Exclusive claims survive restarts; work is never resumed."""

    def __init__(self, directory, clock=time.time):
        self.root, self.clock = Path(directory), clock
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.lock = self.root / "active"

    def path(self, kind, key):
        if kind not in ("receipt", "session", "latest") or not re.fullmatch("[a-f0-9]{64}", key):
            raise TeamsError("invalid_store_key")
        return self.root / f"{kind}-{key}.json"

    def read(self, path):
        try:
            with path.open(encoding="utf-8") as handle:
                value = json.load(handle)
        except FileNotFoundError:
            return None
        if not isinstance(value, dict):
            raise TeamsError("invalid_teams_state", 503)
        return value

    def write(self, path, value):
        data = json.dumps(value, ensure_ascii=True)
        if len(data) > 131072:
            raise TeamsError("teams_state_limit", 503)
        temporary = path.with_name(f"{path.name}.{uuid4().hex}.tmp")
        try:
            with temporary.open("x", encoding="utf-8") as handle:
                os.chmod(temporary, 0o600)
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def claim(self, message):
        path = self.path("receipt", message.operation)
        if path.exists():
            return False
        now = self.clock()
        receipts = list(self.root.glob("receipt-*.json"))
        recent = retained = 0
        for item in receipts:
            modified = item.stat().st_mtime
            if now - modified > 3600:
                item.unlink(missing_ok=True)
            else:
                retained += 1
                if now - modified < 60:
                    recent += 1
        if recent >= 6 or retained >= 512:
            raise TeamsError("teams_rate_limited", 429)
        try:
            with path.open("x", encoding="utf-8") as handle:
                os.chmod(path, 0o600)
                json.dump({"status": "accepted", "at": now}, handle)
        except FileExistsError:
            return False
        return True

    def acquire(self, message):
        try:
            self.lock.mkdir(mode=0o700)
        except FileExistsError:
            expired = self.clock() - self.lock.stat().st_mtime > LOCK_SECONDS
            if message.text == "/reset" and expired:
                (self.lock / "operation.json").unlink(missing_ok=True)
                self.lock.rmdir()
                return self.acquire(message)
            raise TeamsError(
                "previous_outcome_unknown_use_reset" if expired else "teams_request_in_progress",
                409,
            ) from None
        self.write(self.lock / "operation.json", {"operation": message.operation})

    def release(self, message):
        active = self.read(self.lock / "operation.json")
        if active and active["operation"] == message.operation:
            (self.lock / "operation.json").unlink()
            self.lock.rmdir()

    def session(self, message):
        now = self.clock()
        path = self.path("session", message.conversation)
        value = self.read(path)
        if value and value["expires"] > now:
            return value
        sessions = list(self.root.glob("session-*.json"))
        for item in sessions:
            old = self.read(item)
            if old and old["expires"] <= now:
                item.unlink(missing_ok=True)
                latest = item.with_name(item.name.replace("session-", "latest-"))
                latest.unlink(missing_ok=True)
        if len(list(self.root.glob("session-*.json"))) >= 8:
            raise TeamsError("teams_session_limit", 429)
        return {"expires": now + TTL, "history": [], "turns": 0, "fixture": "healthy"}

    def save_session(self, message, session):
        self.write(self.path("session", message.conversation), session)

    def start(self, message):
        self.write(
            self.path("latest", message.conversation),
            {"operation": message.operation, "expires": self.clock() + TTL},
        )

    def complete(self, message, status, answer=""):
        self.write(
            self.path("receipt", message.operation),
            {"status": status, "at": self.clock(), "answer": answer},
        )

    def status(self, message):
        latest = self.read(self.path("latest", message.conversation))
        receipt = (
            self.read(self.path("receipt", latest["operation"]))
            if latest and latest["expires"] > self.clock()
            else None
        )
        if not receipt:
            return "No earlier question is recorded in this conversation."
        status = receipt["status"]
        answer = receipt.get("answer", "")
        if answer:
            return (
                f"Previous request: {status}. Saved result (not a fresh observation):\n\n{answer}"
            )
        return (
            f"Previous request: {status}. It has not been replayed. "
            "If the application restarted, its outcome may be unknown. "
            "Use /reset after four minutes, then ask a new question."
        )


def control(text, session):
    if text == "/help":
        return HELP
    if text == "/reset":
        session.update(history=[], turns=0, fixture="healthy", expires=time.time() + TTL)
        return "Conversation reset. Synthetic healthy fixture selected; no real resource changed."
    if text.startswith("/fixture "):
        fixture = text.removeprefix("/fixture ").strip()
        if fixture not in FIXTURES:
            raise TeamsError("unsupported_fixture")
        session.update(fixture=fixture, history=[], turns=0)
        return f"Synthetic {fixture} fixture selected. History cleared; no real resource changed."
    if text.startswith("/"):
        raise TeamsError("unsupported_command")
    return None


def reply_text(result):
    evidence = "\n".join(
        f"- {item['name']}: observed {item['observedAt']}, queried {item['queriedAt']} "
        f"({item['evidenceId']}; {item['source']})"
        for item in result["tools"][:8]
    )
    text = (
        f"SYNTHETIC EVIDENCE - read-only pilot\n\n{result['answer'][:10000]}\n\n"
        f"Tool observations:\n{evidence or 'No operational tool evidence was returned.'}"
    )
    return text.encode("utf-8")[:20000].decode("utf-8", errors="ignore")
