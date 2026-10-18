"""Bounded SDK stage metadata for the parent's private stderr capture only."""

import json
import re
import sys
import time
from contextlib import contextmanager

SAFE_SDK_CODES = frozenset(
    {
        "Unauthorized",
        "Forbidden",
        "AuthorizationFailed",
        "AuthenticationFailed",
        "InvalidAuthenticationToken",
        "PermissionDenied",
        "NotFound",
        "ResourceNotFound",
        "AgentNotFound",
        "AgentVersionNotFound",
        "BadRequest",
        "InvalidRequest",
        "InvalidArgument",
        "InvalidParameter",
        "InvalidRequestParameter",
        "InvalidApiVersionParameter",
        "ResourceExists",
        "ResourceConflict",
        "Conflict",
        "TooManyRequests",
        "RateLimitExceeded",
        "Throttled",
        "QuotaExceeded",
        "InsufficientQuota",
        "InternalServerError",
        "ServiceUnavailable",
        "GatewayTimeout",
        "RequestTimeout",
        "OperationTimedOut",
        "AccessDenied",
        "AuthorizationPermissionMismatch",
        "PublicNetworkAccessDisabled",
        "ForbiddenByFirewall",
        "403",
        "invalid_request_error",
        "invalid_request",
        "unsupported_parameter",
        "invalid_value",
        "model_not_found",
        "deployment_not_found",
        "insufficient_quota",
        "rate_limit_exceeded",
        "permission_denied",
        "authentication_error",
        "invalid_api_key",
        "server_error",
        "timeout",
    }
)
SAFE_PARAMETERS = frozenset(
    {
        "model",
        "input",
        "store",
        "include",
        "reasoning",
        "reasoning.effort",
        "max_output_tokens",
        "parallel_tool_calls",
        "agent_reference",
        "agent_reference.name",
        "agent_reference.version",
        "tools",
        "tool_choice",
        "conversation",
        "previous_response_id",
    }
)
ACTION_PREFIX = "Microsoft.CognitiveServices/accounts/"
SAFE_REQUIRED_ACTIONS = (
    ACTION_PREFIX + "AIServices/responses/read",
    ACTION_PREFIX + "AIServices/responses/write",
    ACTION_PREFIX + "AIServices/agents/read",
    ACTION_PREFIX + "AIServices/providers/action",
    ACTION_PREFIX + "AIServices/managed-deployments/action",
    ACTION_PREFIX + "AIServices/endpoints/invoke/action",
    ACTION_PREFIX + "OpenAI/deployments/chat/completions/action",
    ACTION_PREFIX + "OpenAI/deployments/completions/action",
)
ACTION_PATTERNS = tuple(
    (
        action,
        re.compile(r"(?<![A-Za-z0-9_./*-])" + re.escape(action) + r"(?![A-Za-z0-9_./*-])", re.I),
    )
    for action in SAFE_REQUIRED_ACTIONS
)


def denial_metadata(messages):
    bounded = [value[:4096] for value in messages if isinstance(value, str)][:6]
    lowered = [value.casefold() for value in bounded]
    network = any(
        "access denied due to virtual network/firewall rules" in value for value in lowered
    )
    rbac = any(
        "does not have access to action" in value or "required rbac permissions" in value
        for value in lowered
    )
    classification = (
        "ambiguous_denial"
        if network and rbac
        else "network_acl_denied"
        if network
        else "rbac_denied"
        if rbac
        else "unknown"
    )
    actions = [
        action
        for action, pattern in ACTION_PATTERNS
        if classification == "rbac_denied" and any(pattern.search(value) for value in bounded)
    ]
    return {
        "classification": classification,
        "requiredAction": actions[0] if len(actions) == 1 else None,
    }


def safe_name(value):
    if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.<>-]{1,128}", value):
        return value
    return "redacted"


def exception_metadata(error):
    status = getattr(error, "status_code", None)
    if type(status) is not int:
        status = getattr(getattr(error, "response", None), "status_code", None)
    if type(status) is not int or not 100 <= status <= 599:
        status = None
    sdk_error = getattr(error, "error", None)
    code_candidates = [
        sdk_error.get("code") if isinstance(sdk_error, dict) else getattr(sdk_error, "code", None),
        getattr(error, "code", None),
    ]
    parameter_candidates = [getattr(error, "param", None)]
    messages = [getattr(error, "message", None)]
    # OpenAI exceptions can carry parsed Azure error envelopes in body rather
    # than .error/.code. Inspect fixed fields only; never emit a body or message.
    for payload in (sdk_error, getattr(error, "body", None)):
        if not isinstance(payload, dict):
            continue
        nested = payload.get("error")
        for node in (payload, nested):
            if not isinstance(node, dict):
                continue
            inner = node.get("innererror")
            for fields in (node, inner):
                if isinstance(fields, dict):
                    code_candidates.append(fields.get("code"))
                    parameter_candidates.append(fields.get("param"))
                    messages.append(fields.get("message"))
    codes = []
    for candidate in code_candidates:
        if isinstance(candidate, str) and candidate in SAFE_SDK_CODES and candidate not in codes:
            codes.append(candidate)
    parameter = next(
        (
            value
            for value in parameter_candidates
            if isinstance(value, str) and value in SAFE_PARAMETERS
        ),
        None,
    )
    frames = []
    trace = error.__traceback__
    while trace is not None:
        frame = trace.tb_frame.f_code
        basename = frame.co_filename.replace("\\", "/").rsplit("/", 1)[-1]
        frames.append(
            {
                "function": safe_name(frame.co_name),
                "file": safe_name(basename),
                "line": trace.tb_lineno,
            }
        )
        # Retain the deepest frames, where transport failures originate.
        frames = frames[-24:]
        trace = trace.tb_next
    return {
        "exceptionType": safe_name(type(error).__name__),
        "httpStatus": status,
        "sdkErrorCode": codes[0] if codes else None,
        "sdkErrorCodes": codes[:4],
        "parameter": parameter,
        **denial_metadata(messages),
        "frames": frames,
    }


def exception_causes(error):
    causes = []
    seen = {id(error)}
    cause = error.__cause__ or error.__context__
    while cause is not None and id(cause) not in seen and len(causes) < 3:
        seen.add(id(cause))
        causes.append(exception_metadata(cause))
        cause = cause.__cause__ or cause.__context__
    return causes


class ManagementDiagnostics:
    def __init__(self, command, stream=None, clock=None):
        self.command = command
        self.stream = stream if stream is not None else sys.stderr
        self.clock = clock or time.monotonic
        self.started = self.clock()
        self.current_stage = None

    def emit(self, event, **metadata):
        print(
            json.dumps(
                {
                    "event": event,
                    "command": self.command,
                    "stage": self.current_stage,
                    "elapsedSeconds": round(max(0, self.clock() - self.started), 3),
                    **metadata,
                },
                separators=(",", ":"),
            ),
            file=self.stream,
            flush=True,
        )

    @contextmanager
    def stage(self, name):
        if name not in ("list_versions", "get", "create_version"):
            raise ValueError("invalid_management_stage")
        self.current_stage = name
        started = self.clock()
        self.emit("management_stage", phase="started", stageElapsedSeconds=0)
        try:
            yield
        except Exception:
            self.emit(
                "management_stage",
                phase="failed",
                stageElapsedSeconds=round(max(0, self.clock() - started), 3),
            )
            raise
        else:
            self.emit(
                "management_stage",
                phase="completed",
                stageElapsedSeconds=round(max(0, self.clock() - started), 3),
            )
            self.current_stage = None

    def failure(self, error):
        self.emit("management_failure", **exception_metadata(error))


class ResponsesDiagnostics(ManagementDiagnostics):
    def __init__(self, stream=None, clock=None):
        super().__init__("responses", stream=stream, clock=clock)
        self.calls = 0

    @contextmanager
    def response(self, round_number):
        self.calls += 1
        call_number = self.calls
        self.current_stage = "responses.create"
        started = self.clock()
        self.emit(
            "responses_stage",
            phase="started",
            call=call_number,
            round=round_number,
            stageElapsedSeconds=0,
        )
        try:
            yield
        except Exception as error:
            self.emit(
                "responses_failure",
                call=call_number,
                round=round_number,
                stageElapsedSeconds=round(max(0, self.clock() - started), 3),
                **exception_metadata(error),
                causes=exception_causes(error),
            )
            raise
        else:
            self.emit(
                "responses_stage",
                phase="completed",
                call=call_number,
                round=round_number,
                stageElapsedSeconds=round(max(0, self.clock() - started), 3),
            )
        finally:
            self.current_stage = None
