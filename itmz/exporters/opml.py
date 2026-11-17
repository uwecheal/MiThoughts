"""OPML 2.0 export (OmniOutliner, Workflowy, Logseq, Obsidian plugins, Dynalist...).

text     -> topic text (Markdown kept as-is)
_note    -> topic note (de-facto standard used by OmniOutliner/Scrivener)
url      -> topic link (type="link")
Extra iThoughts data is kept in `_itmz_*` attributes so nothing is lost.
"""
from __future__ import annotations

import email.utils
import xml.etree.ElementTree as ET

from ..model import ItmzDocument

from .common import normalize_link

EXT = ".opml"
KEEP = ("color", "icon1", "icon2", "folded", "uuid", "task-progress", "task-due", "task-start", "resources")


def render(doc: ItmzDocument) -> bytes:
    data = doc.to_json()
    opml = ET.Element("opml", {"version": "2.0"})
    head = ET.SubElement(opml, "head")
    ET.SubElement(head, "title").text = doc.title()
    ET.SubElement(head, "dateModified").text = email.utils.formatdate(localtime=True)
    body = ET.SubElement(opml, "body")

    def emit(parent, node):
        a = node["attrs"]
        o = ET.SubElement(parent, "outline", {"text": a.get("text", "")})
        if a.get("note"):
            o.set("_note", a["note"])
        if a.get("link"):
            o.set("type", "link")
            o.set("url", normalize_link(a["link"]))
        for k in KEEP:
            if a.get(k):
                o.set("_itmz_" + k.replace("-", "_"), a[k])
        for c in node.get("children") or []:
            emit(o, c)

    for t in data["topics"]:
        emit(body, t)
    ET.indent(opml, space="  ")
    return ET.tostring(opml, encoding="utf-8", xml_declaration=True)


def export(doc: ItmzDocument, out_path: str) -> list[str]:
    with open(out_path, "wb") as f:
        f.write(render(doc))
    return [out_path]
