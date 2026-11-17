"""FreeMind / Freeplane .mm export.

Freeplane is open source and actively maintained, so this export is the
escape hatch for keeping maps *editable* as mind maps outside iThoughts:
text, notes, links, colours, fold state, left/right side, icons (where a
built-in equivalent exists), images and cross-links are carried over.
"""
from __future__ import annotations

import datetime as _dt
import html
import xml.etree.ElementTree as ET

from ..icons import info as icon_info
from ..model import ItmzDocument, parse_pos
from .common import normalize_link, AssetWriter, topic_image

EXT = ".mm"


def _ms(stamp: str | None) -> str | None:
    try:
        return str(int(_dt.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S").timestamp() * 1000))
    except (TypeError, ValueError):
        return None


def _note_html(md: str) -> str:
    paras = [p for p in md.replace("\r", "").split("\n\n")]
    body = "".join("<p>" + html.escape(p).replace("\n", "<br/>") + "</p>" for p in paras)
    return f"<html><head></head><body>{body}</body></html>"


def _fid(u: str) -> str:
    return "ID_" + (u or "").replace("-", "_").upper()


def render(doc: ItmzDocument, assets=None) -> bytes:
    data = doc.to_json()
    mm = ET.Element("map", {"version": "freeplane 1.9.13"})
    rels: dict[str, list[dict]] = {}
    for r in data["relationships"]:
        rels.setdefault((r.get("end1-uuid") or "").upper(), []).append(r)

    def emit(parent, node, depth):
        a = node["attrs"]
        n = ET.SubElement(parent, "node", {"TEXT": a.get("text", ""), "ID": _fid(a.get("uuid"))})
        if depth == 1:
            n.set("POSITION", "left" if parse_pos(a.get("position"))[0] < 0 else "right")
        if a.get("folded") == "1":
            n.set("FOLDED", "true")
        if a.get("color"):
            n.set("BACKGROUND_COLOR", "#" + a["color"])
        if a.get("link"):
            n.set("LINK", normalize_link(a["link"]))
        for k, attr in (("created", "CREATED"), ("modified", "MODIFIED")):
            v = _ms(a.get(k))
            if v:
                n.set(attr, v)
        for k in ("icon1", "icon2"):
            if a.get(k) and icon_info(a[k])[3]:
                ET.SubElement(n, "icon", {"BUILTIN": icon_info(a[k])[3]})
        img = topic_image(doc, a)
        if img and assets:
            ET.SubElement(n, "hook", {"NAME": "ExternalObject", "URI": assets(img)})
        if a.get("note"):
            rc = ET.SubElement(n, "richcontent", {"TYPE": "NOTE"})
            rc.append(ET.fromstring(_note_html(a["note"])))
        for r in rels.get((a.get("uuid") or "").upper(), []):
            al = {"DESTINATION": _fid(r.get("end2-uuid")), "STARTARROW": "None", "ENDARROW": "Default"}
            if r.get("color"):
                al["COLOR"] = "#" + r["color"]
            if r.get("center-text"):
                al["MIDDLE_LABEL"] = r["center-text"]
            ET.SubElement(n, "arrowlink", al)
        for c in node.get("children") or []:
            emit(n, c, depth + 1)

    tops = data["topics"]
    if len(tops) == 1:
        emit(mm, tops[0], 0)
    else:  # FreeMind needs a single root
        root = ET.SubElement(mm, "node", {"TEXT": doc.title(), "ID": "ID_ROOT"})
        for t in tops:
            emit(root, t, 1)
    ET.indent(mm, space=" ")
    return ET.tostring(mm, encoding="utf-8")


def export(doc: ItmzDocument, out_path: str) -> list[str]:
    aw = AssetWriter(doc, out_path)
    with open(out_path, "wb") as f:
        f.write(render(doc, aw))
    return [out_path] + aw.written
