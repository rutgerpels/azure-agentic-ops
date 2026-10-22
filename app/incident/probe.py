"""Bounded Responses contract probe: each step adds one request feature to a plain call.

The probe isolates which request parameter or route the deployed Foundry agent rejects.
It records only status, allowlisted error codes/parameter names and output item types;
it never records prompts, answers, messages, tokens or resource identifiers.
"""

import time

from diagnostics import exception_metadata

PROBE_TEXT = "Connectivity probe. Reply with exactly the single word: ok"
DEVELOPER_TEXT = "Connectivity probe only. Do not call tools."
TOOL_TEXT = (
    'Connectivity probe. Call get_store_context exactly once with countries ["BE"] and '
    "horizon_minutes 60, then reply with exactly the single word: ok"
)
TOOL_OUTPUT = '{"probe":true,"synthetic":true,"stores":[]}'
TIMEOUT_SECONDS = 35
STATELESS = {
    "store": False,
    "include": ["reasoning.encrypted_content"],
    "max_output_tokens": 4096,
    "parallel_tool_calls": False,
}


def steps(settings):
    user = [{"role": "user", "content": PROBE_TEXT}]
    developer = [{"role": "developer", "content": DEVELOPER_TEXT}, *user]
    context = [
        {
            "role": "user",
            "content": "[Server turn context] " + DEVELOPER_TEXT + "\n"
            "[User request]\n" + PROBE_TEXT,
        }
    ]
    history = [
        {"role": "user", "content": "Connectivity probe, first turn."},
        {"role": "assistant", "content": "Acknowledged."},
        *user,
    ]
    agent = {"type": "agent_reference", "name": settings.agent_name}
    pinned = {**agent, "version": settings.agent_version}
    return [
        ("agent_endpoint", "plain_text", {"input": PROBE_TEXT}),
        ("agent_endpoint", "user_message", {"input": user}),
        ("agent_endpoint", "history_messages", {"input": history, **STATELESS}),
        ("agent_endpoint", "developer_message", {"input": developer}),
        ("agent_endpoint", "store_false", {"input": user, "store": False}),
        (
            "agent_endpoint",
            "include_encrypted_reasoning",
            {"input": user, "store": False, "include": ["reasoning.encrypted_content"]},
        ),
        ("agent_endpoint", "max_output_tokens", {"input": user, "max_output_tokens": 4096}),
        ("agent_endpoint", "parallel_tool_calls", {"input": user, "parallel_tool_calls": False}),
        ("agent_endpoint", "previous_runtime_request", {"input": developer, **STATELESS}),
        ("agent_endpoint", "current_runtime_request", {"input": context, **STATELESS}),
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


def tool_roundtrip(responses):
    """Stateless tool loop exactly as the runtime replays it: output items plus call output."""
    record = {"route": "agent_endpoint", "step": "stateless_tool_roundtrip", "toolCalled": False}
    inputs = [{"role": "user", "content": TOOL_TEXT}]
    try:
        first = responses.create(timeout=TIMEOUT_SECONDS, input=inputs, **STATELESS)
        output = [
            item.model_dump(exclude_none=True) if hasattr(item, "model_dump") else dict(item)
            for item in list(getattr(first, "output", None) or [])[:16]
        ]
        calls = [item for item in output if item.get("type") == "function_call"]
        record["toolCalled"] = bool(calls)
        if not calls:
            record.update(accepted=True, **summarize(first))
            return record
        inputs.extend(output)
        inputs.extend(
            {"type": "function_call_output", "call_id": call["call_id"], "output": TOOL_OUTPUT}
            for call in calls
        )
        second = responses.create(timeout=TIMEOUT_SECONDS, input=inputs, **STATELESS)
    except Exception as error:
        metadata = exception_metadata(error)
        metadata.pop("frames", None)
        record.update(accepted=False, **metadata)
    else:
        record.update(accepted=True, **summarize(second))
    return record


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
    started = clock()
    record = tool_roundtrip(clients["agent_endpoint"])
    record["elapsedSeconds"] = round(max(0, clock() - started), 3)
    results.append(record)
    by_step = {item["step"]: item["accepted"] for item in results}
    return {
        "probe": "responses-contract",
        "agentName": settings.agent_name,
        "agentVersion": settings.agent_version,
        "pass": True,
        "currentRuntimeRequestAccepted": by_step["current_runtime_request"],
        "statelessToolLoopAccepted": by_step["stateless_tool_roundtrip"] and record["toolCalled"],
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
