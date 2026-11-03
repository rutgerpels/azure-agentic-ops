"""Fixed-host GitHub App client. There are deliberately no automatic retries."""

import json
import threading
import time
from datetime import datetime
from typing import Any

import httpx
import jwt

from .config import LABEL, MAX_PAGES, MAX_RESPONSE, Settings


class OperationError(Exception):
    """Only fixed, non-sensitive messages may cross the tool boundary."""


def marker(key: str) -> str:
    return f"<!-- orderflow-incident-key:{key} -->"


class GitHub:
    def __init__(self, settings: Settings, client: httpx.Client) -> None:
        self.settings = settings
        self.client = client
        self._token = ""
        self._expires = 0.0
        self._lock = threading.Lock()

    def _request(
        self, method: str, path: str, token: str, *, payload: dict[str, Any] | None = None,
        params: dict[str, str | int] | None = None, expected: int = 200,
    ) -> Any:
        # Paths are constructed exclusively in this module; never follow Location or Link.
        started = time.monotonic()
        try:
            with self.client.stream(
                method, f"https://api.github.com{path}",
                headers={
                    "Authorization": f"Bearer {token}",
                    "Accept": "application/vnd.github+json",
                    "Accept-Encoding": "identity",
                    "X-GitHub-Api-Version": "2026-03-10",
                    "User-Agent": "orderflow-issue-publisher",
                },
                json=payload, params=params, follow_redirects=False,
                timeout=httpx.Timeout(15.0, connect=5.0),
            ) as response:
                if response.status_code != expected:
                    if response.status_code == 401 and token == self._token:
                        # Do not retry this operation. A later observation may mint a fresh token.
                        self._token, self._expires = "", 0.0
                    raise OperationError("GitHub request refused or outcome unknown")
                if response.headers.get("content-encoding", "identity") != "identity":
                    raise OperationError("Encoded GitHub response refused")
                content = bytearray()
                for chunk in response.iter_bytes():
                    if time.monotonic() - started > 30:
                        raise OperationError("GitHub response deadline exceeded; outcome unknown")
                    if len(content) + len(chunk) > MAX_RESPONSE:
                        raise OperationError("GitHub response exceeds the configured bound")
                    content.extend(chunk)
                return json.loads(content)
        except (httpx.HTTPError, ValueError, RecursionError):
            raise OperationError("GitHub request failed or outcome unknown") from None

    def _installation_token(self) -> str:
        with self._lock:
            if self._token and self._expires > time.time() + 120:
                return self._token
            now = int(time.time())
            try:
                app_jwt = jwt.encode(
                    {"iat": now - 60, "exp": now + 540, "iss": self.settings.app_id},
                    self.settings.private_key, algorithm="RS256",
                )
            except (jwt.PyJWTError, ValueError):
                raise OperationError("GitHub App signing failed") from None
            result = self._request(
                "POST", f"/app/installations/{self.settings.installation_id}/access_tokens",
                app_jwt,
                payload={
                    "repository_ids": [self.settings.repository_id],
                    "permissions": {"issues": "write"},
                }, expected=201,
            )
            if not isinstance(result, dict):
                raise OperationError("Invalid installation token response")
            token = result.get("token")
            expiry = result.get("expires_at")
            if not isinstance(token, str) or not token or not isinstance(expiry, str):
                raise OperationError("Invalid installation token response")
            try:
                parsed_expiry = datetime.fromisoformat(expiry.replace("Z", "+00:00"))
                if parsed_expiry.tzinfo is None:
                    raise ValueError
                expires = parsed_expiry.timestamp()
            except ValueError:
                raise OperationError("Invalid installation token expiry") from None
            if expires <= time.time() + 120:
                raise OperationError("Installation token expires too soon")
            repo = self._request("GET", f"/repos/{self.settings.repository}", token)
            if (
                not isinstance(repo, dict)
                or type(repo.get("id")) is not int
                or repo["id"] != self.settings.repository_id
                or not isinstance(repo.get("full_name"), str)
                or repo["full_name"].lower() != self.settings.repository.lower()
            ):
                raise OperationError("Installation repository identity mismatch")
            self._token, self._expires = token, expires
            return token

    def _reference(self, issue: Any, key: str) -> dict[str, Any]:
        if (
            not isinstance(issue, dict)
            or type(issue.get("number")) is not int
            or issue["number"] <= 0
            or "pull_request" in issue
            or not isinstance(issue.get("body"), str)
            or marker(key) not in issue["body"].splitlines()
        ):
            raise OperationError("Issue evidence did not match the incident marker")
        number = issue["number"]
        url = f"https://github.com/{self.settings.repository}/issues/{number}"
        if (
            not isinstance(issue.get("html_url"), str)
            or issue["html_url"].lower() != url.lower()
        ):
            raise OperationError("Issue reference escaped the configured repository")
        return {"number": number, "url": url}

    def find(self, key: str) -> dict[str, Any] | None:
        token = self._installation_token()
        found = None
        for page in range(1, MAX_PAGES + 1):
            items = self._request(
                "GET", f"/repos/{self.settings.repository}/issues", token,
                params={
                    "state": "all", "labels": LABEL, "per_page": 100,
                    "page": page, "sort": "created", "direction": "desc",
                },
            )
            if not isinstance(items, list) or len(items) > 100:
                raise OperationError("Invalid issue listing")
            for item in items:
                if not isinstance(item, dict):
                    raise OperationError("Invalid issue listing")
                body = item.get("body")
                if (
                    "pull_request" not in item and isinstance(body, str)
                    and marker(key) in body.splitlines()
                ):
                    if found is not None:
                        raise OperationError(
                            "Multiple issues match this incident; manual review required"
                        )
                    found = self._reference(item, key)
            if len(items) < 100:
                return found
        # Never interpret a truncated scan as absence, even if a candidate was found.
        raise OperationError("Issue scan limit reached; manual reconciliation required")

    def read(self, number: int, key: str) -> dict[str, Any]:
        return self._reference(
            self._request(
                "GET", f"/repos/{self.settings.repository}/issues/{number}",
                self._installation_token(),
            ), key,
        )

    def create(self, key: str, title: str, body: str) -> dict[str, Any]:
        return self._reference(
            self._request(
                "POST", f"/repos/{self.settings.repository}/issues", self._installation_token(),
                payload={"title": title, "body": f"{body}\n\n{marker(key)}", "labels": [LABEL]},
                expected=201,
            ), key,
        )
