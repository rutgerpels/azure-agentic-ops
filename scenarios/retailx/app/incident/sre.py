"""GET-only SRE observations; no model-supplied endpoints, IDs or transcript text."""

import asyncio
import hashlib
import json
import re
import time
from datetime import timedelta
from urllib.parse import quote, urlsplit
from uuid import UUID

from evidence import LIVE_MAX_AGE, envelope, parse_time

RESOURCE = r"/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/"
READ_TIMEOUT_SECONDS = 20
NATIVE_NOTE_FIELDS = frozenset({
    "author", "text", "timeStamp", "submittedAt", "posted", "id",
    "incidentDiscussionId", "isComplete", "isDailyReport", "isImageContent",
    "messageType", "delivery", "attachments",
})


def validate_binding(settings):
    endpoint = urlsplit(settings.sre_endpoint)
    if (
        endpoint.scheme != "https"
        or endpoint.username
        or endpoint.password
        or endpoint.port not in (None, 443)
        or endpoint.path not in ("", "/")
        or endpoint.query
        or endpoint.fragment
        or not re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)*\.azuresre\.ai", endpoint.hostname or "")
    ):
        raise ValueError("invalid_sre_endpoint")
    if not re.fullmatch(RESOURCE + r"Microsoft\.App/agents/[A-Za-z0-9_-]+", settings.sre_resource):
        raise ValueError("invalid_sre_resource")
    group = settings.sre_resource.rsplit("/providers/", 1)[0].lower()
    for resource, kind in (
        (settings.workspace_resource, r"Microsoft\.OperationalInsights/workspaces"),
        (settings.sre_latency_rule, r"Microsoft\.Insights/scheduledQueryRules"),
        (settings.sre_service_rule, r"Microsoft\.Insights/scheduledQueryRules"),
    ):
        if (
            not re.fullmatch(RESOURCE + kind + r"/[A-Za-z0-9_.()-]+", resource)
            or resource.rsplit("/providers/", 1)[0].lower() != group
        ):
            raise ValueError("invalid_sre_scope")
    return parse_time(settings.checkout_created_at)


def unknown_progress(now, reason, *, synthetic=False):
    return {
        **envelope(
            "synthetic-sre-fixture" if synthetic else "owned-checkout-sre",
            now,
            synthetic=synthetic,
            status="unknown",
            reason=reason,
        ),
        "incidents": [],
        "completionProven": False,
        "causeConfirmed": False,
    }


def fixture_progress(now, state):
    result = unknown_progress(now, "no_correlated_sre_fixture", synthetic=True)
    states = {
        "interrupted": "investigating",
        "slow": "awaiting-approval",
        "recovering": "executing",
        "healthy": "reported-complete",
    }
    if state in states:
        work = states[state]
        result.update(
            **envelope("synthetic-sre-fixture", now, now, synthetic=True),
            incidents=[
                {
                    "incidentRef": "synthetic-service" if state != "slow" else "synthetic-latency",
                    "kind": "latency" if state == "slow" else "service",
                    "countries": ["BE"] if state == "slow" else ["BE", "NL"],
                    "workState": work,
                    "lastActivityAt": now.isoformat(),
                    "reportedCause": (
                        "The shared price service was stopped." if state == "healthy" else None
                    ),
                    "completionReported": work == "reported-complete",
                }
            ],
        )
    return result


def thread_progress(thread, now):
    """Reduce known structured states and explicit assistant conclusions, never user text."""
    messages = thread.get("value")
    if (
        not isinstance(messages, list)
        or len(messages) > 200
        or thread.get("nextLink")
        or thread.get("continuationToken")
        or any(not isinstance(message, dict) for message in messages)
    ):
        raise ValueError("incomplete_sre_thread")
    result = {
        "workState": "unknown",
        "lastActivityAt": None,
        "reportedCause": None,
        "completionReported": False,
    }
    approvals, executions = [], []
    for message in messages:
        for key, values in (("approval", approvals), ("azCliExecution", executions)):
            if key in message and message[key] is not None:
                action = message[key]
                if not isinstance(action, dict) or not isinstance(action.get("status"), str):
                    raise ValueError("invalid_sre_action")
                values.append(action["status"])
    if any(status not in ("Approved", "Rejected", "Expired", "Pending") for status in approvals):
        return result
    if any(status not in ("Completed", "Failed", "Pending", "Running") for status in executions):
        return result
    if "Pending" in approvals:
        result["workState"] = "awaiting-approval"
    elif any(status not in ("Completed", "Failed") for status in executions):
        result["workState"] = "executing"
    elif thread.get("state") == "Running":
        result["workState"] = "investigating"
    elif thread.get("state") == "Idle":
        result["workState"] = "idle"
    else:
        return result

    # Preview schemas without a dated, plain assistant message cannot establish a conclusion.
    notes = []
    for message in messages:
        if any(key in message for key in ("author", "text", "timeStamp")):
            if any(key in message for key in ("role", "content", "createdAt")):
                return result
            author = message.get("author")
            plain = (
                isinstance(author, dict)
                and author.get("role") == "SREAgent"
                and message.get("isComplete") is True
                and message.get("messageType") is None
                and not message.get("isDailyReport")
                and not message.get("isImageContent")
                and not message.get("attachments")
                and not any(
                    value is not None for key, value in message.items()
                    if key not in NATIVE_NOTE_FIELDS
                )
            )
            stamp_value = message.get("timeStamp")
            role = "assistant" if plain else None
            content = message.get("text") if plain else None
        else:
            stamp_value = message.get("createdAt")
            role = message.get("role")
            content = message.get("content")
        if not stamp_value:
            return result
        stamp = parse_time(stamp_value)
        if stamp > now + timedelta(seconds=30):
            raise ValueError("future_sre_message")
        notes.append((stamp, role, content))
    if not notes:
        return result
    stamp = max(note[0] for note in notes)
    result["lastActivityAt"] = stamp.isoformat()
    latest = [note for note in notes if note[0] == stamp]
    if len(latest) != 1:
        return result
    _, role, text = latest[0]
    if role != "assistant" or not isinstance(text, str):
        return result
    if len(text) > 16000:
        raise ValueError("sre_note_limit")
    # Only a small cause vocabulary crosses into the business agent, never raw SRE prose.
    for sentence in re.split(r"[.!?\n]", text.lower()):
        if not re.search(r"\broot cause\s*:", sentence) or re.search(
            r"\b(?:not|no|unconfirmed|unknown|possible|likely|may|might|suspect)\b", sentence
        ):
            continue
        if re.search(r"\bprice service (?:was|is|had been) stopped\b", sentence):
            result["reportedCause"] = "The shared price service was stopped."
        elif re.search(r"\bbelgium\b.*\brout(?:e|ed|ing)\b.*\blegacy\b", sentence):
            result["reportedCause"] = (
                "Belgium checkout traffic was routed to the legacy price path."
            )
    if result["workState"] == "idle" and any(
        re.fullmatch(r"investigation (?:is|has been) complete", sentence.strip(), re.I)
        for sentence in re.split(r"[.!?\n]", text)
    ):
        result.update(workState="reported-complete", completionReported=True)
    return result


class SreReader:
    def __init__(self, settings, credential_factory=None):
        self.settings = settings
        self.credential_factory = credential_factory or self._credential

    @staticmethod
    def _credential():
        from azure.identity.aio import ManagedIdentityCredential

        return ManagedIdentityCredential(retry_total=0, connection_timeout=2, read_timeout=3)

    async def _get(self, client, url, audience, deadline, *, credential, allow_missing=False):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("sre_read_deadline")
        token = (await credential.get_token(audience + "/.default")).token
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("sre_read_deadline")
        async with client.stream(
            "GET",
            url,
            headers={"Authorization": f"Bearer {token}"},
            timeout=min(5, remaining),
        ) as response:
            if allow_missing and response.status_code == 404:
                return None
            response.raise_for_status()
            content = bytearray()
            async for chunk in response.aiter_bytes():
                if time.monotonic() >= deadline or len(content) + len(chunk) > 512_000:
                    raise ValueError("sre_read_limit")
                content.extend(chunk)
            data = json.loads(content)
        if not isinstance(data, dict):
            raise ValueError("invalid_sre_response")
        return data

    def progress(self, countries, health, now):
        settings = self.settings
        result = unknown_progress(now, "sre_binding_missing")
        if not settings.sre_resource:
            return result
        import httpx
        from azure.core.exceptions import AzureError
        from telemetry import event

        try:
            created = validate_binding(settings)
            if created > now:
                raise ValueError("future_checkout_generation")
            return asyncio.run(self._progress(countries, health, now, created))
        except (
            ValueError,
            KeyError,
            TypeError,
            AttributeError,
            TimeoutError,
            httpx.HTTPError,
            AzureError,
        ):
            event("sre_evidence_error", reason="sre_read_failed")
            result["reason"] = "sre_read_failed"
            return result

    async def _progress(self, countries, health, now, created):
        import httpx

        settings = self.settings
        deadline = time.monotonic() + READ_TIMEOUT_SECONDS
        workspace = settings.workspace_resource
        subscription = settings.sre_resource.split("/")[2]
        async with (
            asyncio.timeout(READ_TIMEOUT_SECONDS),
            self.credential_factory() as credential,
            httpx.AsyncClient(follow_redirects=False) as client,
        ):
            # Revalidate ownership and endpoint before sending a data-plane credential.
            resource = await self._get(
                client,
                f"https://management.azure.com{settings.sre_resource}?api-version=2026-01-01",
                "https://management.azure.com",
                deadline,
                credential=credential,
            )
            if (
                resource.get("id", "").lower() != settings.sre_resource.lower()
                or resource.get("tags", {}).get("ownerToken") != settings.checkout_owner
                or resource.get("properties", {}).get("agentEndpoint", "").rstrip("/")
                != settings.sre_endpoint.rstrip("/")
            ):
                raise ValueError("sre_owner_or_endpoint_mismatch")
            alerts = await self._get(
                client,
                f"https://management.azure.com/subscriptions/{subscription}"
                "/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01"
                f"&targetResource={quote(workspace, safe='')}&timeRange=30d&pageCount=100",
                "https://management.azure.com",
                deadline,
                credential=credential,
            )
            if (
                not isinstance(alerts.get("value"), list)
                or len(alerts["value"]) > 100
                or alerts.get("nextLink")
            ):
                raise ValueError("incomplete_alert_discovery")
            candidates = {}
            for alert in alerts["value"]:
                essential = alert["properties"]["essentials"]
                rule = essential["alertRule"].lower()
                if (
                    essential["targetResource"].lower() != workspace.lower()
                    or rule
                    not in (settings.sre_latency_rule.lower(), settings.sre_service_rule.lower())
                    or (rule == settings.sre_latency_rule.lower() and "BE" not in countries)
                ):
                    continue
                started = parse_time(essential["startDateTime"])
                if started < created or started > now + timedelta(seconds=30):
                    continue
                # Do not present an old resolved occurrence as the current incident.
                if essential["monitorCondition"] not in ("Fired", "Resolved"):
                    raise ValueError("unknown_monitor_condition")
                # There is no authoritative latency fault occurrence token in telemetry.
                # A resolved latency alert cannot identify a later fault/recovery follow-up.
                if (
                    rule == settings.sre_latency_rule.lower()
                    and essential["monitorCondition"] != "Fired"
                ):
                    continue
                if essential["monitorCondition"] == "Resolved" and started < now - timedelta(
                    minutes=30
                ):
                    continue
                if rule == settings.sre_service_rule.lower():
                    fault = health.get("serviceFaultStartedAt")
                    if not fault or started < parse_time(fault) - timedelta(seconds=30):
                        continue
                candidates.setdefault(rule, []).append((started, alert))
            incidents = []
            for rule, matches in candidates.items():
                if len(matches) != 1:
                    raise ValueError("ambiguous_incident_occurrence")
                started, alert = matches[0]
                alert_id = alert["id"]
                identifier = str(UUID(alert_id.split("/")[-1]))
                expected_ids = (
                    f"/subscriptions/{subscription}/providers/Microsoft.AlertsManagement/alerts/{identifier}",
                    f"{workspace}/providers/Microsoft.AlertsManagement/alerts/{identifier}",
                )
                if alert_id.lower() not in (value.lower() for value in expected_ids):
                    raise ValueError("invalid_alert_id")
                reference = hashlib.sha256(alert_id.lower().encode()).hexdigest()[:16]
                kind = "latency" if rule == settings.sre_latency_rule.lower() else "service"
                incident = await self._get(
                    client,
                    settings.sre_endpoint.rstrip("/")
                    + f"/api/v2/incidentManagement/incidents?incidentId={identifier}",
                    "https://azuresre.dev",
                    deadline,
                    credential=credential,
                    allow_missing=True,
                )
                if incident is None:
                    incidents.append(
                        {
                            "incidentRef": reference,
                            "kind": kind,
                            "countries": ["BE"]
                            if rule == settings.sre_latency_rule.lower()
                            else list(countries),
                            "workState": "not-found",
                            "completionReported": False,
                            "reportedCause": None,
                            "lastActivityAt": None,
                        }
                    )
                    continue
                if (
                    str(UUID(incident["id"])) != identifier
                    or incident["alertId"].lower() != alert_id.lower()
                    or incident["targetResourceId"].lower() != workspace.lower()
                    or incident["alertRuleResourceId"].lower() != rule
                ):
                    raise ValueError("sre_incident_linkage_mismatch")
                thread_id = str(UUID(incident["threadId"]))
                thread = await self._get(
                    client,
                    settings.sre_endpoint.rstrip("/") + f"/api/v1/threads/{thread_id}/messages",
                    "https://azuresre.dev",
                    deadline,
                    credential=credential,
                )
                progress = thread_progress(thread, now)
                if progress["lastActivityAt"] and parse_time(progress["lastActivityAt"]) < started:
                    raise ValueError("sre_note_predates_incident")
                incidents.append(
                    {
                        **progress,
                        "incidentRef": reference,
                        "kind": kind,
                        "countries": ["BE"]
                        if rule == settings.sre_latency_rule.lower()
                        else list(countries),
                    }
                )
        return {
            **unknown_progress(now, "no_correlated_incident"),
            **envelope("owned-checkout-sre", now, now, max_age=LIVE_MAX_AGE),
            "incidents": incidents,
            "reason": None if incidents else "no_correlated_incident",
        }
