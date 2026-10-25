"""Separate Teams-only host. Browser Easy Auth, cookies and CSRF are not bypassed."""

import asyncio
import json
import logging

from agent import AgentError, FoundryAgent
from aiohttp import web
from config import Settings, managed_identity_credential
from evidence import EvidenceService
from microsoft_agents.activity import Activity
from microsoft_agents.authentication.msal import MsalConnectionManager
from microsoft_agents.hosting.aiohttp import CloudAdapter, jwt_authorization_middleware
from microsoft_agents.hosting.core import AgentAuthConfiguration, OutboundHostValidator
from microsoft_agents.hosting.core.authorization.auth_types import AuthTypes
from teams import (
    ReceiptStore,
    TeamsError,
    TeamsSettings,
    admit,
    control,
    reply_text,
    validate_evidence_mode,
)
from telemetry import configure, event


def create_teams_app(settings=None, teams_settings=None, agent=None, adapter=None, store=None):
    settings = settings or Settings.from_env()
    teams_settings = teams_settings or TeamsSettings.from_env(settings)
    validate_evidence_mode(settings)
    configure(events_only=True)
    # SDK transport diagnostics may contain activity bodies or token failure details.
    logging.getLogger("microsoft_agents").setLevel(logging.CRITICAL)
    configuration = AgentAuthConfiguration(
        auth_type=AuthTypes.user_managed_identity,
        client_id=teams_settings.client_id,
        tenant_id=teams_settings.tenant,
        connection_name="SERVICE_CONNECTION",
        anonymous_allowed=False,
    )
    if adapter is None:
        connections = MsalConnectionManager(
            connections_configurations={"SERVICE_CONNECTION": configuration}
        )
        adapter = CloudAdapter(
            connection_manager=connections, host_validator=OutboundHostValidator(enabled=True)
        )

    async def on_turn_error(_context, error):
        # The SDK default prints a traceback and echoes the raw exception to the user.
        raise error

    adapter.on_turn_error = on_turn_error
    credential = None
    owned_agent = agent is None
    if owned_agent:
        credential = managed_identity_credential()
        agent = FoundryAgent(settings, EvidenceService(settings, credential))
    store = store or ReceiptStore(
        teams_settings.directory, claims_directory=teams_settings.claims_directory
    )
    tasks = set()

    @web.middleware
    async def boundary(request, handler):
        if request.method == "GET" and request.path == "/health/live":
            return web.Response(text='{"status":"ok"}', content_type="application/json")
        if request.method != "POST" or request.path != "/api/messages":
            return web.json_response({"error": "not_found"}, status=404)
        if len(request.headers.getall("Authorization", [])) != 1:
            return web.json_response({"error": "authentication_required"}, status=401)
        if request.content_type != "application/json":
            return web.json_response({"error": "json_required"}, status=415)
        try:
            return await handler(request)
        except TeamsError as error:
            event("teams_request_rejected", errorType=error.code)
            return web.json_response({"error": error.code}, status=error.status)
        except web.HTTPException:
            raise
        except Exception as error:
            event("teams_request_failed", errorType=type(error).__name__)
            return web.json_response({"error": "teams_request_failed"}, status=503)

    app = web.Application(
        middlewares=[boundary, jwt_authorization_middleware], client_max_size=65536
    )
    app["agent_configuration"] = configuration

    async def send(context, text):
        await asyncio.wait_for(
            context.send_activity(Activity(type="message", text=text, text_format="plain")),
            timeout=20,
        )

    async def run_turn(message, session, continuation):
        cancelled = False
        try:
            result = await asyncio.to_thread(
                agent.turn, list(session["history"]), message.text, ["BE", "NL"], session["fixture"]
            )
            if not result.get("contentFiltered"):
                session["history"].extend(
                    [
                        {"role": "user", "content": message.text},
                        {"role": "assistant", "content": result["answer"][:4000]},
                    ]
                )
                session["history"] = session["history"][-8:]
                while len(json.dumps(session["history"])) > 100000:
                    session["history"] = session["history"][2:]
            session["turns"] += 1
            store.save_session(message, session)
            answer = reply_text(result, settings.mode)
            store.complete(message, "delivery-started", answer)

            async def deliver(context):
                await send(context, answer)

            await asyncio.wait_for(
                adapter.continue_conversation(teams_settings.client_id, continuation, deliver),
                timeout=30,
            )
            store.complete(message, "delivered", answer)
            event(
                "teams_turn_completed", toolCount=len(result["tools"]), evidenceMode=settings.mode
            )
        except asyncio.CancelledError:
            cancelled = True
            event("teams_turn_outcome_unknown", errorType="cancelled")
            # The worker thread might still be running; leave its durable lock in place.
            raise
        except Exception as error:
            # Inference or delivery may already have happened. Never retry either automatically.
            code = (
                error.code if isinstance(error, (TeamsError, AgentError)) else type(error).__name__
            )
            event("teams_turn_outcome_unknown", errorType=code)
            previous = store.read(store.path("receipt", message.operation))
            store.complete(message, "outcome-unknown", (previous or {}).get("answer", ""))
        finally:
            if not cancelled:
                store.release(message)

    def finished(task):
        tasks.discard(task)
        try:
            task.result()
        except asyncio.CancelledError:
            event("teams_task_cancelled")
        except Exception as error:
            event("teams_state_persistence_failed", errorType=type(error).__name__)

    async def messages(request):
        claims = request["claims_identity"]
        if (
            claims.allow_anonymous
            or claims.claims.get("iss") != "https://api.botframework.com"
            or claims.get_app_id() != teams_settings.client_id
        ):
            raise TeamsError("channel_token_required", 401)
        try:
            payload = await request.json()
        except (ValueError, UnicodeDecodeError):
            raise TeamsError("invalid_json") from None
        if not isinstance(payload, dict):
            raise TeamsError("invalid_activity")
        # Installation/typing events cannot invoke tools or send messages.
        if payload.get("type") in ("installationUpdate", "conversationUpdate", "typing"):
            return web.Response(status=200)
        message = admit(payload, teams_settings)
        if not store.claim(message):
            return web.Response(status=200)
        activity = Activity.model_validate(payload)

        async def on_turn(context):
            if message.text == "/status":
                await send(context, store.status(message))
                store.complete(message, "delivered")
                return
            if tasks:
                raise TeamsError("teams_request_in_progress", 409)
            store.acquire(message)
            handed_off = False
            try:
                session = store.session(message)
                answer = control(message.text, session, settings.mode)
                if answer is not None:
                    store.save_session(message, session)
                    store.complete(message, "delivery-started", answer)
                    await send(context, answer)
                    store.complete(message, "delivered", answer)
                    return
                if session["turns"] >= 8:
                    raise TeamsError("turn_limit_reset_required", 429)
                store.start(message)
                label = "live checkout" if settings.mode == "live" else "synthetic"
                await send(context, f"Checking fresh {label} evidence. Use /status if interrupted.")
                continuation = activity.get_conversation_reference().get_continuation_activity()
                task = asyncio.create_task(run_turn(message, session, continuation))
                tasks.add(task)
                task.add_done_callback(finished)
                handed_off = True
            finally:
                if not handed_off:
                    store.release(message)

        try:
            await adapter.process_activity(claims, activity, on_turn)
        except Exception:
            previous = store.read(store.path("receipt", message.operation))
            store.complete(message, "outcome-unknown", (previous or {}).get("answer", ""))
            raise
        return web.Response(status=200)

    async def cleanup(_app):
        if tasks:
            await asyncio.gather(*tasks)
        if owned_agent:
            agent.close()
            credential.close()

    async def health(_request):
        return web.Response(text='{"status":"ok"}', content_type="application/json")

    app.router.add_get("/health/live", health)
    app.router.add_post("/api/messages", messages)
    app.on_cleanup.append(cleanup)
    return app


if __name__ == "__main__":
    web.run_app(create_teams_app(), host="0.0.0.0", port=8000, access_log=None)
