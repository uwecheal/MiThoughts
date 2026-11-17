"""Markdown export.

Levels 0..HEADING_LEVELS-1 become headings, deeper topics nested bullets
(the same convention iThoughts' own Markdown export uses).  Notes are kept
as Markdown (iThoughts notes already are Markdown), attachments are copied
into <name>.assets/ and linked relatively.
"""
from __future__ import annotations

from ..icons import emoji
from ..model import ItmzDocument
from .common import AssetWriter, normalize_link, one_line, rewrite_note_refs, task_summary, topic_image, topic_label_index

EXT = ".md"
HEADING_LEVELS = 2


def render(doc: ItmzDocument, assets=None) -> str:
    data = doc.to_json()
    assets = assets or (lambda p: p)
    out: list[str] = []

    def block(lines_text: str, indent: str):
        for line in lines_text.splitlines():
            out.append((indent + line) if line.strip() else "")

    def emit(node, depth):
        a = node["attrs"]
        icons = "".join(emoji(a[k]) + " " for k in ("icon1", "icon2") if a.get(k))
        text = a.get("text", "")
        if depth < HEADING_LEVELS:
            out.append("#" * (depth + 1) + " " + icons + one_line(text))
            out.append("")
            ind = ""
        else:
            ind = "    " * (depth - HEADING_LEVELS)
            first, *rest = (text or "·").splitlines() or ["·"]
            out.append(f"{ind}- {icons}{first}")
            for r in rest:
                out.append(f"{ind}  {r}" if r.strip() else "")
            ind += "  "
        extras = []
        img = topic_image(doc, a)
        if img:
            extras.append(f"![]({assets(img)})")
        if a.get("link"):
            url = normalize_link(a["link"])
            extras.append(f"Link: <{url}>" if url == a["link"] else f"Link: [{a['link']}]({url})")
        ts = task_summary(a)
        if ts:
            extras.append(f"Task: {ts}")
        if extras:
            if depth >= HEADING_LEVELS:
                out.append("")
            for e in extras:
                out.append(ind + e + "  ")
            out.append("")
        if a.get("note"):
            note = rewrite_note_refs(a["note"], a.get("uuid", ""), doc, assets)
            if depth >= HEADING_LEVELS and not extras:
                out.append("")
            block(note, ind)
            out.append("")
        for c in node.get("children") or []:
            emit(c, depth + 1)
        if depth < HEADING_LEVELS and out and out[-1] != "":
            out.append("")

    for t in data["topics"]:
        emit(t, 0)

    if data["relationships"]:
        labels = topic_label_index(data)
        out += ["", "## Relationships", ""]
        for r in data["relationships"]:
            a = labels.get((r.get("end1-uuid") or "").lower(), "?")
            b = labels.get((r.get("end2-uuid") or "").lower(), "?")
            lbl = f" — {r['center-text']}" if r.get("center-text") else ""
            out.append(f"- {a} → {b}{lbl}")
    text = "\n".join(out)
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.strip() + "\n"


def export(doc: ItmzDocument, out_path: str) -> list[str]:
    aw = AssetWriter(doc, out_path)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(render(doc, aw))
    return [out_path] + aw.written
