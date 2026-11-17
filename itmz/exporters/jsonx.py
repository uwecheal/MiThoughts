"""JSON export: every attribute of every topic, relationships, groups,
style and the raw manifest - a neutral, script-friendly full dump.
Attachments are copied into <name>.assets/ like the Markdown export."""
from __future__ import annotations

import json

from ..model import ItmzDocument
from .common import AssetWriter

EXT = ".json"


def export(doc: ItmzDocument, out_path: str) -> list[str]:
    aw = AssetWriter(doc, out_path)
    data = doc.to_json()
    data = {"format": "itmz-studio/json-1", **data,
            "assets": {name: aw(name) for name in doc.asset_names()}}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    return [out_path] + aw.written
