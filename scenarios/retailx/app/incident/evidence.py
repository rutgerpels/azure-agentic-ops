"""Bounded, read-only evidence. Never turn missing or stale data into success."""

import json
import re
import uuid
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

UTC = UTC
COUNTRIES = ("BE", "NL")
SYNTHETIC_STORES = {
    "BE": (("BE-101", 7, 22), ("BE-102", 8, 20), ("BE-205", 9, 21), ("BE-310", 7, 22)),
    "NL": (("NL-401", 7, 22), ("NL-402", 8, 20), ("NL-517", 9, 21), ("NL-620", 7, 22)),
}
STATES = (
    "healthy",
    "interrupted",
    "recovering",
    "stale",
    "unknown",
    "unavailable",
    "ownership-mismatch",
)
MAX_AGE = 180
# Arc Syslog and App Insights ingestion lag by minutes; live freshness allows for that.
LIVE_MAX_AGE = 300
LIVE_WINDOW_MINUTES = 5
MARKER_PHASES = ("prepared", "fault-active", "recovering", "recovered")

COUNTRY_SCHEMA = {
    "type": "array",
    "items": {"type": "string", "enum": list(COUNTRIES)},
    "minItems": 1,
    "maxItems": 2,
}
TOOLS = {}
for name, description in (
    (
        "get_checkout_health",
        "Retrieve NEW operational checkout evidence for explicit BE/NL countries.",
    ),
    (
        "get_store_context",
        "Retrieve synthetic opening windows for BE/NL stores, not operational health.",
    ),
    (
        "assess_store_impact",
        "Retrieve NEW health and opening evidence; prioritize observed failures separately "
        "from shared exposure.",
    ),
):
    properties = {"countries": COUNTRY_SCHEMA}
    if name != "get_checkout_health":
        properties = {
            **properties,
            "horizon_minutes": {"type": "integer", "minimum": 1, "maximum": 60},
        }
    TOOLS[name] = {
        "name": name,
        "description": description,
        "strict": True,
        "parameters": {
            "type": "object",
            "properties": properties,
            "required": list(properties),
            "additionalProperties": False,
        },
    }


class ToolArgumentError(ValueError):
    pass


def validate_arguments(name, arguments, scope):
    if name not in TOOLS or type(arguments) is not dict:
        raise ToolArgumentError("unknown_tool_or_invalid_object")
    required = set(TOOLS[name]["parameters"]["required"])
    if set(arguments) != required:
        raise ToolArgumentError("unexpected_or_missing_arguments")
    countries = arguments.get("countries")
    if (
        type(countries) is not list
        or not 1 <= len(countries) <= 2
        or any(type(c) is not str or c not in COUNTRIES or c not in scope for c in countries)
        or len(set(countries)) != len(countries)
    ):
        raise ToolArgumentError("invalid_country_scope")
    if "horizon_minutes" in required:
        horizon = arguments["horizon_minutes"]
        if type(horizon) is not int or not 1 <= horizon <= 60:
            raise ToolArgumentError("invalid_horizon")
    return sorted(countries)


def parse_time(value):
    if not isinstance(value, str):
        raise ValueError("invalid_observation_time")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("observation_timezone_missing")
    return result.astimezone(UTC)


def fresh(observed, now, max_age=MAX_AGE):
    return -30 <= (now - observed).total_seconds() <= max_age


def envelope(
    source,
    now,
    observed=None,
    *,
    synthetic=False,
    state=None,
    status="known",
    reason=None,
    max_age=MAX_AGE,
):
    valid = observed is not None and fresh(observed, now, max_age)
    return {
        "evidenceId": "ev-" + uuid.uuid4().hex,
        "queriedAt": now.isoformat(),
        "observedAt": observed.isoformat() if observed else None,
        "source": source,
        "synthetic": synthetic,
        "fixture": synthetic and source == "synthetic-fixture",
        "fixtureState": state,
        "maxAgeSeconds": max_age,
        "ageSeconds": round((now - observed).total_seconds(), 3) if observed else None,
        "status": status if valid else "unknown",
        "reason": reason if valid or reason else "missing_stale_or_future_observation",
    }


def store_context(countries, horizon, now):
    stores = []
    for country in countries:
        zone = ZoneInfo("Europe/Brussels" if country == "BE" else "Europe/Amsterdam")
        local_now = now.astimezone(zone)
        # Everyday synthetic schedule deliberately avoids pretending to know a real retailer.
        for store_id, opening_hour, closing_hour in SYNTHETIC_STORES[country]:
            opened = local_now.replace(hour=opening_hour, minute=0, second=0, microsecond=0)
            closed = local_now.replace(hour=closing_hour, minute=0, second=0, microsecond=0)
            is_open = opened <= local_now < closed
            next_open = opened if local_now < opened else opened + timedelta(days=1)
            opening_soon = not is_open and now <= next_open.astimezone(UTC) <= now + timedelta(
                minutes=horizon
            )
            stores.append(
                {
                    "store": store_id,
                    "country": country,
                    "timezone": str(zone),
                    "isOpen": is_open,
                    "opensWithinHorizon": opening_soon,
                    "nextOpening": next_open.isoformat(),
                    "openingToday": opened.isoformat(),
                    "closingToday": closed.isoformat(),
                    "synthetic": True,
                }
            )
    return {
        **envelope("synthetic-store-map", now, now, synthetic=True),
        "horizonMinutes": horizon,
        "stores": stores,
        "limitation": (
            "Synthetic opening context only; these are not real stores or verified store outages."
        ),
    }


def fixture_health(countries, state, now):
    if state not in STATES:
        raise ValueError("invalid_fixture_state")
    observed = now - timedelta(seconds=181) if state == "stale" else now
    unknown_reason = {
        "stale": "stale_observation",
        "unknown": "unknown_observation",
        "unavailable": "source_unavailable",
        "ownership-mismatch": "ownership_mismatch",
    }.get(state)
    result = envelope(
        "synthetic-fixture",
        now,
        observed,
        synthetic=True,
        state=state,
        status="unknown" if unknown_reason else "known",
        reason=unknown_reason,
    )
    result["countries"] = []
    for country in countries:
        failures = 12 if state == "interrupted" else 2 if state == "recovering" else 0
        result["countries"].append(
            {
                "country": country,
                "health": "unknown" if unknown_reason else "degraded" if failures else "healthy",
                "observedFailedCheckouts": None if unknown_reason else failures,
                "observedSuccessfulCheckouts": None if unknown_reason else 30,
                "observedFailedStores": []
                if unknown_reason or not failures
                else [SYNTHETIC_STORES[country][0][0]],
                "sharedDependencyExposed": not unknown_reason
                and state in ("interrupted", "recovering"),
                "countryAggregateOnly": False,
            }
        )
    result["recoveryProven"] = False
    result["limitation"] = (
        "SYNTHETIC fixture, not a live outage. Healthy baseline does not prove incident recovery. "
        "Failed checkouts alone do not establish lost revenue, failed payments, or store outages."
    )
    return result


def validate_receipt(receipt, settings, now):
    if not isinstance(receipt, dict):
        return "invalid_service_receipt"
    if receipt.get("ownerToken") != settings.checkout_owner:
        return "ownership_mismatch"
    if (
        type(receipt.get("schemaVersion")) is not int
        or receipt["schemaVersion"] != 1
        or receipt.get("service") != "retailtx-price-primary.service"
        or receipt.get("event") != "checkout-service-observation"
        or type(receipt.get("active")) is not bool
        or type(receipt.get("healthy")) is not bool
    ):
        return "invalid_service_receipt"
    if receipt["healthy"] and not receipt["active"]:
        return "inconsistent_service_receipt"
    # Bound to the checkout deployment owner and freshness, not to a presenter run: the
    # assistant observes whichever fault the presenter injects and never claims recovery.
    marker = receipt.get("marker")
    if marker is not None and (
        not isinstance(marker, dict)
        or marker.get("scenario") != "service"
        or marker.get("phase") not in MARKER_PHASES
    ):
        return "invalid_service_marker"
    try:
        if not fresh(parse_time(receipt.get("observedAtUtc")), now, LIVE_MAX_AGE):
            return "stale_or_future_service_observation"
    except (ValueError, TypeError):
        return "invalid_service_observation_time"
    return None


def marker_summary(receipt):
    """Expose only the recorded controller phase and times, never run or actor IDs."""
    marker = receipt.get("marker")
    if marker is None:
        return {"serviceIncidentPhase": "no-fault-recorded"}

    def stamp(key):
        try:
            return parse_time(marker.get(key)).isoformat()
        except (ValueError, TypeError):
            return None

    return {
        "serviceIncidentPhase": marker["phase"],
        "serviceFaultStartedAt": stamp("startedAtUtc"),
        "serviceRecordedRecoveryAt": stamp("recoveredAtUtc"),
    }


class LiveReader:
    """Fixed workspace and exact resources only; KQL never accepts model text."""

    def __init__(self, settings, credential):
        self.settings = settings
        self.credential = credential

    def _query(self, query):
        import httpx

        token = self.credential.get_token("https://api.loganalytics.io/.default").token
        with httpx.Client(timeout=12, follow_redirects=False) as client:
            response = client.post(
                f"https://api.loganalytics.io/v1/workspaces/{self.settings.workspace}/query",
                headers={"Authorization": f"Bearer {token}"},
                json={"query": query, "timespan": "PT10M"},
            )
            response.raise_for_status()
            data = response.json()
        if data.get("error") or len(data.get("tables", [])) != 1:
            raise ValueError("incomplete_query_result")
        table = data["tables"][0]
        columns = [c["name"] for c in table["columns"]]
        if len(table["rows"]) > 51:
            raise ValueError("query_result_limit")
        return [dict(zip(columns, row, strict=True)) for row in table["rows"]]

    def health(self, countries, now):
        settings = self.settings
        result = envelope(
            "owned-checkout-log-analytics", now, status="unknown", max_age=LIVE_MAX_AGE
        )
        result.update(
            countries=[],
            recoveryProven=False,
            observationWindowMinutes=LIVE_WINDOW_MINUTES,
            limitation=(
                "Country/store request samples are not proof of store outages or incident "
                "recovery. A 'recovered' controller phase is a recorded repair, not verified "
                "customer recovery."
            ),
        )
        try:
            uuid.UUID(settings.workspace)
            resources = (settings.workspace_resource, settings.arc_resource, settings.app_resource)
            if not all(
                re.fullmatch(
                    r"/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/"
                    r"[A-Za-z0-9_.()-]+/providers/[A-Za-z0-9./_-]+",
                    v,
                )
                for v in resources
            ) or not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", settings.checkout_owner):
                raise ValueError("invalid_live_binding")
        except (ValueError, AttributeError):
            result["reason"] = "live_binding_missing_or_invalid"
            return result
        try:
            receipts = self._query(
                "Syslog | where TimeGenerated > ago(10m) "
                f"| where _ResourceId =~ '{settings.arc_resource}' "
                "and ProcessName == 'RetailTxCheckout' "
                "| extend r=parse_json(SyslogMessage) "
                f"| where tostring(r.ownerToken) == '{settings.checkout_owner}' "
                "and tostring(r.event) == 'checkout-service-observation' "
                "| extend observed=todatetime(r.observedAtUtc) "
                "| top 1 by observed desc | project receipt=tostring(r)"
            )
            if len(receipts) != 1:
                result["reason"] = "missing_owned_arc_observation"
                return result
            receipt = json.loads(receipts[0]["receipt"])
            reason = validate_receipt(receipt, settings, now)
            if reason:
                result["reason"] = reason
                return result
            # The request stream has no fault token; only a short recent window is sampled and
            # recovery is deliberately never inferred from it.
            observed = parse_time(receipt["observedAtUtc"])
            rows = self._query(
                f"AppRequests | where TimeGenerated > ago({LIVE_WINDOW_MINUTES}m) "
                f"| where _ResourceId =~ '{settings.app_resource}' "
                "| where Name == 'POST /checkout' "
                "| extend country=tostring(Properties['retail.country']), "
                "store=tostring(Properties['retail.store']), "
                "channel=tostring(Properties['retail.channel']) "
                "| where country in ('BE','NL') and channel in ('pos','web') "
                "| summarize failed=countif(Success == false), succeeded=countif(Success == true), "
                "latest=max(TimeGenerated) by country, store | take 51"
            )
            # The extra row is a sentinel, not evidence to aggregate. A bounded
            # subset must never hide failures from an omitted country/store group.
            if len(rows) > 50:
                result["reason"] = "request_group_limit_exceeded"
                return result
            if not rows:
                result["reason"] = "missing_recent_checkout_requests"
                return result
            result = {
                **result,
                **envelope("owned-checkout-log-analytics", now, observed, max_age=LIVE_MAX_AGE),
                **marker_summary(receipt),
            }
            result["serviceActive"] = receipt["active"]
            result["serviceHealthy"] = receipt["healthy"]
            for country in countries:
                matches = [r for r in rows if r["country"] == country]
                fresh_rows = [
                    r for r in matches if fresh(parse_time(r["latest"]), now, LIVE_MAX_AGE)
                ]
                if not fresh_rows:
                    result["countries"].append(
                        {
                            "country": country,
                            "health": "unknown",
                            "observedFailedCheckouts": None,
                            "observedFailedStores": [],
                            "sharedDependencyExposed": not receipt["healthy"],
                            "countryAggregateOnly": True,
                        }
                    )
                    continue
                failed = sum(int(r["failed"]) for r in fresh_rows)
                failed_stores = sorted(
                    {
                        r["store"]
                        for r in fresh_rows
                        if int(r["failed"]) > 0 and re.fullmatch(country + r"-[0-9]{3}", r["store"])
                    }
                )
                result["countries"].append(
                    {
                        "country": country,
                        "health": "degraded" if failed or not receipt["healthy"] else "healthy",
                        "observedFailedCheckouts": failed,
                        "observedSuccessfulCheckouts": sum(int(r["succeeded"]) for r in fresh_rows),
                        "observedFailedStores": failed_stores,
                        "sharedDependencyExposed": not receipt["healthy"],
                        "countryAggregateOnly": failed > 0 and not failed_stores,
                    }
                )
            if any(c["health"] == "unknown" for c in result["countries"]):
                result.update(status="unknown", reason="incomplete_country_evidence")
            return result
        except Exception as error:
            # Return an explicit unknown, never raw SDK/HTTP text or partially healthy results.
            result.update(status="unknown", reason="live_query_failed", countries=[])
            from telemetry import event

            event("evidence_error", errorType=type(error).__name__)
            return result


class EvidenceService:
    def __init__(self, settings, credential=None, clock=None, live_reader=None):
        self.settings = settings
        self.clock = clock or (lambda: datetime.now(UTC))
        self.live = live_reader or LiveReader(settings, credential)

    def execute(self, name, arguments, scope, state):
        countries = validate_arguments(name, arguments, scope)
        now = self.clock()
        if name == "get_store_context":
            result = store_context(countries, arguments["horizon_minutes"], now)
        else:
            health = (
                fixture_health(countries, state, now)
                if self.settings.mode == "fixture"
                else self.live.health(countries, now)
            )
            if name == "get_checkout_health":
                result = health
            else:
                context = store_context(countries, arguments["horizon_minutes"], now)
                priorities = []
                for store in context["stores"]:
                    country = next(
                        (c for c in health["countries"] if c["country"] == store["country"]), {}
                    )
                    urgent_window = store["isOpen"] or store["opensWithinHorizon"]
                    observed_failure = store["store"] in country.get("observedFailedStores", [])
                    if (
                        health["status"] == "unknown"
                        or country.get("health", "unknown") == "unknown"
                    ):
                        priority, why = "investigate", "missing_or_untrusted_operational_evidence"
                    elif observed_failure and urgent_window:
                        priority, why = (
                            "P1",
                            "fresh_observed_checkout_failures_open_or_opening_store",
                        )
                    elif country.get("sharedDependencyExposed") and urgent_window:
                        priority, why = (
                            "P2",
                            "shared_dependency_exposure_not_observed_store_failure",
                        )
                    elif observed_failure:
                        priority, why = "P3", "observed_checkout_failures_outside_opening_window"
                    else:
                        priority, why = "monitor", "no_observed_failure_not_proof_of_recovery"
                    priorities.append(
                        {
                            "store": store["store"],
                            "country": store["country"],
                            "priority": priority,
                            "reason": why,
                            "observedCheckoutFailuresAtStore": observed_failure,
                            "exposedToSharedDependency": country.get(
                                "sharedDependencyExposed", False
                            ),
                            "storeOutageProven": False,
                        }
                    )
                priorities.sort(
                    key=lambda p: (
                        {"P1": 0, "P2": 1, "investigate": 2, "P3": 3, "monitor": 4}[p["priority"]],
                        p["store"],
                    )
                )
                result = {
                    **envelope(
                        "deterministic-impact-assessment",
                        now,
                        parse_time(health["observedAt"]) if health["observedAt"] else None,
                        synthetic=self.settings.mode == "fixture",
                        state=health["fixtureState"],
                        status=health["status"],
                        reason=health["reason"],
                        max_age=health["maxAgeSeconds"],
                    ),
                    "health": health,
                    "storeContext": context,
                    "priorities": priorities,
                    "recoveryProven": False,
                    "limitation": (
                        "Synthetic store map; failed checkouts do not prove lost revenue, "
                        "failed payments or store outages."
                    ),
                }
        result["evidenceMode"] = self.settings.mode
        if self.settings.mode == "fixture":
            result["fixtureState"] = state
        return result
