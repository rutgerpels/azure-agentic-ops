"""Generate a private personal-scope Teams ZIP using only the Python standard library."""

import argparse
import json
import re
import struct
import zlib
from pathlib import Path
from uuid import UUID
from zipfile import ZIP_DEFLATED, ZipFile

DOC = "https://github.com/rutgerpels/azure-agentic-ops/blob/main/scenarios/retailx/docs/teams-pilot.md"


def icon(size, outline=False):
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        )

    pixels = bytearray()
    for y in range(size):
        pixels.append(0)
        for x in range(size):
            mark = (
                size // 4 <= x < size * 3 // 4
                and size // 4 <= y < size * 3 // 4
                and (x < size // 3 or y < size // 3 or size * 5 // 12 <= y < size // 2)
            )
            pixels.extend(
                (255, 255, 255, 255) if mark else ((0, 0, 0, 0) if outline else (17, 72, 110, 255))
            )
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(pixels)))
        + chunk(b"IEND", b"")
    )


def build_package(bot_id, app_id, hostname, output):
    bot_id, app_id = str(UUID(bot_id)), str(UUID(app_id))
    if not re.fullmatch(r"app-rtx-teams-[a-z0-9.-]+\.azurewebsites\.net", hostname):
        raise ValueError("Expected the owned Teams App Service hostname")
    manifest = {
        "$schema": "https://developer.microsoft.com/json-schemas/teams/v1.19/MicrosoftTeams.schema.json",
        "manifestVersion": "1.19",
        "version": "1.0.0",
        "id": app_id,
        "developer": {
            "name": "Retailx demo",
            "websiteUrl": DOC,
            "privacyUrl": f"{DOC}#privacy",
            "termsOfUseUrl": f"{DOC}#terms-of-use",
        },
        "name": {"short": "Retailx incident pilot", "full": "Retailx read-only incident assistant"},
        "description": {
            "short": "Personal, read-only synthetic checkout incident pilot.",
            "full": "Ask about synthetic checkout impact and store opening hours. "
            "Evidence is synthetic. No infrastructure actions or automatic remediation.",
        },
        "icons": {"outline": "outline.png", "color": "color.png"},
        "accentColor": "#11486E",
        "bots": [
            {
                "botId": bot_id,
                "scopes": ["personal"],
                "isNotificationOnly": False,
                "supportsFiles": False,
                "commandLists": [
                    {
                        "scopes": ["personal"],
                        "commands": [
                            {"title": "/help", "description": "Pilot boundaries and commands"},
                            {
                                "title": "/status",
                                "description": "Previous request status; no automatic replay",
                            },
                            {
                                "title": "/reset",
                                "description": "Clear conversation and select healthy fixture",
                            },
                            {
                                "title": "/fixture interrupted",
                                "description": "Select synthetic interruption",
                            },
                        ],
                    }
                ],
            }
        ],
        "validDomains": [hostname],
    }
    with ZipFile(Path(output), "w", compression=ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, indent=2))
        archive.writestr("color.png", icon(192))
        archive.writestr("outline.png", icon(32, outline=True))
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ("bot-id", "app-id", "hostname", "output"):
        parser.add_argument(f"--{field}", required=True)
    args = parser.parse_args()
    build_package(args.bot_id, args.app_id, args.hostname, args.output)
