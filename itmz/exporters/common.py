"""Helpers shared by all exporters."""
from __future__ import annotations

import mimetypes
import os
import re
import base64

from ..model import ItmzDocument

TASK_KEYS = ("task-progress", "task-start", "task-due", "task-priority", "task-effort", "resources", "cost")


def topic_image(doc: ItmzDocument, attrs: dict) -> str | None:
    """Zip path of a topic's image (assets/<att-id>/<att-name>), if present."""
    aid = attrs.get("att-id")
    if not aid:
        return None
    name = attrs.get("att-name")
    if name and f"assets/{aid}/{name}" in doc.files:
        return f"assets/{aid}/{name}"
    for n in doc.files:                     # att-name is sometimes missing
        if n.startswith(f"assets/{aid}/"):
            return n
    return None


def rewrite_note_refs(note: str, topic_uuid: str, doc: ItmzDocument, mapper) -> str:
    """Notes reference attachments by bare file name (stored in notes/<uuid>/).
    Rewrite `](file)` and `[n]: file` to whatever mapper(zip_path) returns."""
    if not note or not topic_uuid:
        return note or ""
    prefix = f"notes/{topic_uuid}/"
    if not any(n.startswith(prefix) for n in doc.files):
        return note

    def sub(m):
        target = m.group(2)
        zp = prefix + target
        return m.group(1) + (mapper(zp) if zp in doc.files else target) + m.group(3)
    note = re.sub(r"(\]\()([^)\s]+)(\))", sub, note)
    note = re.sub(r"(^\s*\[[^\]]+\]:\s*)(\S+)(.*)$", sub, note, flags=re.M)
    return note


class AssetWriter:
    """Copies attachments next to an exported file: <stem>.assets/<zip path>."""

    def __init__(self, doc: ItmzDocument, out_path: str):
        self.doc = doc
        stem = os.path.splitext(os.path.basename(out_path))[0]
        self.folder = stem + ".assets"
        self.base = os.path.join(os.path.dirname(os.path.abspath(out_path)), self.folder)
        self.written: list[str] = []

    def __call__(self, zip_path: str) -> str:
        data = self.doc.files.get(zip_path)
        if data is None:
            return zip_path
        dest = os.path.join(self.base, *zip_path.split("/"))
        if dest not in self.written:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(data)
            self.written.append(dest)
        rel = self.folder + "/" + zip_path
        return rel.replace(" ", "%20")


def data_uri(name: str, data: bytes) -> str:
    mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
    return f"data:{mime};base64,{base64.b64encode(data).decode()}"


def normalize_link(link: str) -> str:
    """iThoughts stores links as typed: 'www.x.org', 'me@x.org', 'https://..'."""
    link = (link or "").strip()
    if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", link):
        return link
    if re.fullmatch(r"[^@\s/]+@[^@\s/]+\.[^@\s/]+", link):
        return "mailto:" + link
    m = re.fullmatch(r"([\w-]+(?:\.[\w-]+)+)(/\S*)?", link)
    if m and (link.startswith("www.") or m.group(1).count(".") >= 2 or m.group(2)
              or m.group(1).rsplit(".", 1)[1] in ("com", "org", "net", "edu", "ch", "de", "uk", "io")):
        return "http://" + link
    return link


def one_line(text: str) -> str:
    """Topic text as a single heading-friendly line."""
    lines = [re.sub(r"^\s*#+\s*", "", l).strip() for l in (text or "").splitlines()]
    return " ".join(l for l in lines if l) or "·"


def task_summary(a: dict) -> str:
    bits = []
    if a.get("task-progress"):
        p = int(float(a["task-progress"]))
        bits.append("done" if p > 100 else f"{p}%")
    if a.get("task-priority"):
        bits.append(f"P{a['task-priority']}")
    if a.get("task-start"):
        bits.append("start " + a["task-start"].replace("T", " ")[:16])
    if a.get("task-due"):
        bits.append("due " + a["task-due"].replace("T", " ")[:16])
    if a.get("task-effort") and not a["task-effort"].startswith("-"):
        bits.append("effort " + a["task-effort"])
    if a.get("resources"):
        bits.append("@" + a["resources"])
    if a.get("cost"):
        bits.append("cost " + a["cost"])
    return " · ".join(bits)


def topic_label_index(data: dict) -> dict[str, str]:
    from ..model import walk
    return {(t["attrs"].get("uuid") or "").lower(): one_line(t["attrs"].get("text", "")) for t, _, _ in walk(data["topics"])}
