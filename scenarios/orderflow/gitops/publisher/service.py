"""At most one issue creation attempt per externally reserved incident key."""

from typing import Annotated, Any

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator

from .config import KEY_PATTERN
from .github import GitHub, OperationError
from .receipts import Receipts

IncidentKey = Annotated[str, StringConstraints(strict=True, pattern=f"^{KEY_PATTERN}$")]


class FindInput(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    incident_key: IncidentKey


class PublishInput(FindInput):
    title: str = Field(min_length=1, max_length=200)
    body: str = Field(min_length=1, max_length=24_000)

    @field_validator("title", "body")
    @classmethod
    def safe_text(cls, value: str) -> str:
        if (
            not value.strip() or "orderflow-incident-key:" in value
            or any(ord(char) < 32 and char not in "\n\t" for char in value)
            or any(0xD800 <= ord(char) <= 0xDFFF or ord(char) == 127 for char in value)
        ):
            raise ValueError("Invalid issue text")
        return value

    @field_validator("title")
    @classmethod
    def single_line(cls, value: str) -> str:
        if "\n" in value or "\t" in value:
            raise ValueError("Title must be a single line")
        return value


class Publisher:
    def __init__(self, github: GitHub, receipts: Receipts) -> None:
        self.github = github
        self.receipts = receipts

    def _observe(self, key: str, *, confirm: bool = False) -> tuple[dict[str, Any], bool]:
        if key != self.github.settings.generation:
            raise OperationError("Incident key must equal the configured owner generation")
        receipt = self.receipts.read(key)
        if receipt is not None and receipt["issue"] is not None:
            issue = self.github.read(receipt["issue"]["number"], key)
            return {"status": "found", "incident_key": key, "issue": issue}, True
        issue = self.github.find(key)
        if issue is not None:
            if receipt is not None and confirm:
                self.receipts.complete(key, issue)
            return {"status": "found", "incident_key": key, "issue": issue}, True
        if receipt is not None:
            return {
                "status": "unknown", "incident_key": key,
                "message": "Reserved attempt not observed on GitHub; never submit a second POST",
            }, True
        return {"status": "not_found", "incident_key": key}, False

    def find(self, inputs: FindInput) -> dict[str, Any]:
        try:
            return self._observe(inputs.incident_key)[0]
        except OperationError as error:
            return {"status": "unknown", "incident_key": inputs.incident_key, "message": str(error)}

    def publish(self, inputs: PublishInput) -> dict[str, Any]:
        key = inputs.incident_key
        try:
            observed, stop = self._observe(key, confirm=True)
            if stop:
                return observed
            if not self.receipts.reserve(key):
                # Another replica won, including one whose GitHub write is still in flight.
                observed, _ = self._observe(key, confirm=True)
                if observed["status"] == "not_found":
                    raise OperationError(
                        "Reservation exists but receipt unavailable; do not replay"
                    )
                return observed
            issue = self.github.create(key, inputs.title, inputs.body)
            self.receipts.complete(key, issue)
            return {"status": "published", "incident_key": key, "issue": issue}
        except OperationError as error:
            return {"status": "unknown", "incident_key": key, "message": str(error)}
