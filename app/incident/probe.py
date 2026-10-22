"""Bounded Responses contract probe: each step adds one request feature to a plain call.

The probe isolates which request parameter or route the deployed Foundry agent rejects.
It records only status, allowlisted error codes/parameter names and output item types;
it never records prompts, answers, messages, tokens or resource identifiers.
"""

import time

from diagnostics import exception_metadata

PROBE_TEXT = "Connectivity probe. Reply with exactly the single word: ok"
DEVELOPER_TEXT = "Connectivity probe only. Do not call tools."
TIMEOUT_SECONDS = 35


def steps(settings):
    user = [{"role": "user", "content": PROBE_TEXT}]
    developer = [{"role": "developer", "content": DEVELOPER_TEXT}, *user]
    agent = {"type": "agent_reference", "name": settings.agent_name}
    pinned = {**agent, "version": settings.agent_version}
    return [
        ("agent_endpoint", "plain_text", {"input": PROBE_TEXT}),
        ("agent_endpoint", "user_message", {"input": user}),
        ("agent_endpoint", "developer_message", {"input": developer}),
        ("agent_endpoint", "store_false", {"input": user, "store": False}),
        (
            "agent_endpoint",
            "include_encrypted_reasoning",
            {"input": user, "store": False, "include": ["reasoning.encrypted_content"]},
        ),
        ("agent_endpoint", "max_output_tokens", {"input": user, "max_output_tokens": 4096}),
        ("agent_endpoint", "parallel_tool_calls", {"input": user, "parallel_tool_calls": False}),
        (
            "agent_endpoint",
            "current_runtime_request",
            {
                "input": developer,
                "store": False,
                "include": ["reasoning.encrypted_content"],
                "max_output_tokens": 4096,
                "parallel_tool_calls": False,
            },
        ),
        ("project_endpoint", "agent_reference", {"input": user, "extra_body": {"agent": agent}}),
        (
            "project_endpoint",
            "agent_reference_pinned",
            {"input": user, "extra_body": {"agent": pinned}},
        ),
    ]


def summarize(response):
    output = list(getattr(response, "output", None) or [])
    types = []
    for item in output[:16]:
        kind = item.get("type") if isinstance(item, dict) else getattr(item, "type", None)
        types.append(kind if isinstance(kind, str) and kind.isidentifier() else "other")
    text = getattr(response, "output_text", None)
    status = getattr(response, "status", None)
    return {
        "responseStatus": status if status in ("completed", "incomplete", "failed") else "other",
        "outputTypes": types,
        "answeredOk": isinstance(text, str) and text.strip().strip(".").lower() == "ok",
    }


def run(settings, clients, clock=time.monotonic):
    """clients maps route name to an OpenAI-compatible responses object."""
    results = []
    for route, name, request in steps(settings):
        started = clock()
        record = {"route": route, "step": name}
        try:
            response = clients[route].create(timeout=TIMEOUT_SECONDS, **request)
        except Exception as error:
            metadata = exception_metadata(error)
            metadata.pop("frames", None)
            record.update(accepted=False, **metadata)
        else:
            record.update(accepted=True, **summarize(response))
        record["elapsedSeconds"] = round(max(0, clock() - started), 3)
        results.append(record)
    by_step = {item["step"]: item["accepted"] for item in results}
    return {
        "probe": "responses-contract",
        "agentName": settings.agent_name,
        "agentVersion": settings.agent_version,
        "pass": True,
        "currentRuntimeRequestAccepted": by_step["current_runtime_request"],
        "anyAccepted": any(by_step.values()),
        "steps": results,
        "limitation": "Request acceptance only; not model-behavior or live-incident evidence.",
    }


def probe(settings):
    from agent import project_client

    project, credential = project_client(settings)
    agent_client = project.get_openai_client(
        agent_name=settings.agent_name, timeout=TIMEOUT_SECONDS, max_retries=0
    )
    project_openai = project.get_openai_client(timeout=TIMEOUT_SECONDS, max_retries=0)
    try:
        return run(
            settings,
            {
                "agent_endpoint": agent_client.responses,
                "project_endpoint": project_openai.responses,
            },
        )
    finally:
        agent_client.close()
        project_openai.close()
        project.close()
        credential.close()
