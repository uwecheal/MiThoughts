"""Lossless reader/writer for iThoughts .itmz files.

Design rule: the XML DOM of mapdata.xml *is* the model.  Editors change a
small, well-defined set of attributes (MANAGED_ATTRS) and the tree
structure; every other attribute, element and zip entry is carried through
untouched.  That is what keeps saved files openable by iThoughtsX/iOS.

Only the Python standard library is used.
"""
from __future__ import annotations

import datetime as _dt
import io
import os
import plistlib
import re
import shutil
import tempfile
import uuid as _uuid
import zipfile
import xml.etree.ElementTree as ET

# Attributes the editor is allowed to change.  Anything else is read-only
# and is preserved byte-for-byte (modulo XML re-serialisation).
MANAGED_ATTRS = ("text", "note", "link", "color", "icon1", "icon2", "folded", "position")

_POS_RE = re.compile(r"\{\s*([-+0-9.eE]+)\s*,\s*([-+0-9.eE]+)\s*\}")


class ItmzError(Exception):
    pass


# ---------------------------------------------------------------- helpers
def parse_pos(s: str | None) -> tuple[float, float]:
    m = _POS_RE.match(s or "")
    return (float(m.group(1)), float(m.group(2))) if m else (0.0, 0.0)


def _fmt_num(v: float) -> str:
    if abs(v - round(v)) < 1e-6:
        return str(int(round(v)))
    return ("%.6f" % v).rstrip("0").rstrip(".")


def fmt_pos(x: float, y: float) -> str:
    return "{%s, %s}" % (_fmt_num(x), _fmt_num(y))


def now_stamp() -> str:
    """Timestamp format used by iThoughts (local time, no zone)."""
    return _dt.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def new_uuid() -> str:
    return str(_uuid.uuid4()).upper()


def _same_pos(a: str | None, b: str | None) -> bool:
    (ax, ay), (bx, by) = parse_pos(a), parse_pos(b)
    return abs(ax - bx) < 0.01 and abs(ay - by) < 0.01


# ---------------------------------------------------------------- document
class ItmzDocument:
    """An opened .itmz file.

    >>> doc = ItmzDocument.load("Help/Help.itmz")
    >>> data = doc.to_json()          # plain dict for the UI / exporters
    >>> doc.apply_json(data)          # write edits back into the DOM
    >>> doc.save()                    # repack (atomic, optional backup)
    """

    def __init__(self, raw: bytes, path: str | None = None):
        self.path = path
        try:
            zf = zipfile.ZipFile(io.BytesIO(raw))
        except zipfile.BadZipFile as e:
            raise ItmzError(f"not a zip archive: {e}") from e
        with zf:
            # keep original order of entries
            self.entries: list[tuple[str, bytes]] = [(i.filename, zf.read(i)) for i in zf.infolist() if not i.is_dir()]
        self.files = dict(self.entries)
        if "mapdata.xml" not in self.files:
            raise ItmzError("mapdata.xml missing - not an iThoughts map")
        self.root = ET.fromstring(self.files["mapdata.xml"])
        if self.root.tag != "iThoughts":
            raise ItmzError(f"unexpected root element <{self.root.tag}>")
        self.style = None
        if "style.xml" in self.files:
            try:
                self.style = ET.fromstring(self.files["style.xml"])
            except ET.ParseError:
                self.style = None

    # ---- construction
    @classmethod
    def load(cls, path: str) -> "ItmzDocument":
        with open(path, "rb") as f:
            return cls(f.read(), path)

    @classmethod
    def new(cls, title: str = "Central Topic") -> "ItmzDocument":
        ts = now_stamp()
        root = ET.Element("iThoughts", {
            "version": "4.0", "app": "com.toketaware.ithoughtsx", "app-version": "9.4",
            "modified": ts, "author": "itmz-studio", "system-version": "itmz-studio",
        })
        topics = ET.SubElement(root, "topics")
        topics.text = "\n"
        t = ET.SubElement(topics, "topic", {"uuid": new_uuid(), "position": "{0, 0}", "text": title,
                                            "created": ts, "modified": ts})
        t.text = "\n"
        t.tail = "\n"
        rel = ET.SubElement(root, "relationships")
        rel.text = "\n"
        rel.tail = "\n"
        topics.tail = ""
        mapdata = ET.tostring(root, encoding="unicode").encode("utf-8")
        style = (b'<style version="2" name="" canvasStyle="0" mapLayout="1" handDrawnTopics="0" topicHugging="1" '
                 b'layoutDensity="0" radialLayout="0" mapViewStyle="0" level1LinkStyle="5" level1LinkStyleTapered="1" '
                 b'levelNLinkStyle="3" linkThickness="2" autoAlign="1" calloutShape="0" rainbow="0" rainbowStartColor="" '
                 b'rainbowRange="0" rainbowClockwise="1" rainbowAngularDistribution="0" inheritColor="1" linkColor=""  '
                 b'calloutFont="HelveticaNeue | Helvetica Neue |  | " calloutFontSize="14" '
                 b'noteFont="HelveticaNeue | Helvetica Neue |  | " noteFontSize="14">'
                 b'<level n="0" topicShape="2" textFont="Helvetica | Helvetica |  | " textFontSize="14" />'
                 b'<level n="1" topicShape="0" /></style>')
        prefs = plistlib.dumps({"HideCompletedTasks": False, "SnapToTopic": True})
        manifest = plistlib.dumps({"AppID": "com.toketaware.ithoughtsx", "AppVersion": "9.4"})
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            for name, data in (("mapdata.xml", mapdata), ("style.xml", style),
                               ("manifest.plist", manifest), ("preferences.plist", prefs)):
                z.writestr(name, data)
        doc = cls(buf.getvalue())
        doc._refresh_manifest()
        return doc

    # ---- read access
    @property
    def topics_el(self) -> ET.Element:
        el = self.root.find("topics")
        if el is None:
            el = ET.SubElement(self.root, "topics")
        return el

    def iter_topics(self):
        return self.topics_el.iter("topic")

    def title(self) -> str:
        first = self.topics_el.find("topic")
        return (first.get("text") or "Untitled").strip() if first is not None else "Untitled"

    def asset_names(self) -> list[str]:
        return [n for n, _ in self.entries if n.startswith(("assets/", "notes/"))]

    def read_file(self, name: str) -> bytes | None:
        return self.files.get(name)

    def to_json(self) -> dict:
        """Everything a UI or exporter needs, as plain JSON-able data.

        Topic attributes are passed through with their original iThoughts
        names so there is a single vocabulary across Python and JS.
        """
        def topic(el):
            return {"attrs": dict(el.attrib), "children": [topic(c) for c in el.findall("topic")]}

        def rows(tag, child):
            p = self.root.find(tag)
            return [dict(e.attrib) for e in p.findall(child)] if p is not None else []

        style = None
        if self.style is not None:
            style = {"attrs": dict(self.style.attrib),
                     "levels": {lv.get("n"): dict(lv.attrib) for lv in self.style.findall("level")}}
        return {
            "meta": dict(self.root.attrib),
            "style": style,
            "topics": [topic(t) for t in self.topics_el.findall("topic")],
            "relationships": rows("relationships", "relationship"),
            "groups": rows("groups", "group"),
            "files": self.asset_names(),
        }

    # ---- write access
    def apply_json(self, data: dict) -> dict:
        """Apply an edited tree (same shape as to_json()['topics']).

        * existing topics (matched by uuid) get MANAGED_ATTRS updated,
          all other attributes untouched;
        * topics without a known uuid are created;
        * topics missing from `data` are deleted;
        * children order/parentage follows `data`.
        Returns a small change report.
        """
        index = {el.get("uuid"): el for el in self.iter_topics()}
        seen: set[str] = set()
        stamp = now_stamp()
        report = {"created": 0, "changed": 0, "deleted": 0, "moved": 0}
        old_parent = {c.get("uuid"): p.get("uuid") for p in self.topics_el.iter() for c in p.findall("topic")}

        def build(node: dict, parent_uuid):
            a = node.get("attrs") or {}
            uid = a.get("uuid") or new_uuid()
            if uid in seen:
                raise ItmzError(f"topic {uid} appears twice in edited tree")
            seen.add(uid)
            el = index.get(uid)
            changed = False
            if el is None:
                el = ET.Element("topic", {"uuid": uid, "position": a.get("position") or "{0, 0}"})
                el.set("created", stamp)
                report["created"] += 1
                changed = True
            elif old_parent.get(uid) != parent_uuid:
                report["moved"] += 1
                changed = True
            for k in MANAGED_ATTRS:
                nv, ov = a.get(k), el.get(k)
                if nv is not None and not isinstance(nv, str):
                    nv = str(nv)
                if k == "position":
                    if nv and not _same_pos(nv, ov):
                        el.set(k, nv)
                        changed = True
                elif nv in (None, ""):
                    if ov is not None:
                        del el.attrib[k]
                        changed = True
                elif nv != ov:
                    el.set(k, nv)
                    changed = True
            if changed:
                el.set("modified", stamp)
                if uid in index:
                    report["changed"] += 1
                _canonical_attr_order(el)
            kids = [build(c, uid) for c in node.get("children") or []]
            others = [c for c in el if c.tag != "topic"]
            el[:] = kids + others
            el.text = "\n"
            for k in kids:
                k.tail = "\n"
            return el

        tops = [build(n, None) for n in data.get("topics") or []]
        if not tops:
            raise ItmzError("a map needs at least one topic")
        te = self.topics_el
        te[:] = tops
        te.text = "\n"
        for t in tops:
            t.tail = "\n"
        report["deleted"] = len(set(index) - seen)
        self._drop_dangling_refs(seen)
        self.root.set("modified", stamp)
        self.files["mapdata.xml"] = self.mapdata_bytes()
        self._refresh_manifest()
        return report

    def _drop_dangling_refs(self, alive: set[str]):
        alive_l = {u.lower() for u in alive}
        ok = lambda u: (u or "").lower() in alive_l
        rels = self.root.find("relationships")
        if rels is not None:
            for r in list(rels):
                if not (ok(r.get("end1-uuid")) and ok(r.get("end2-uuid"))):
                    rels.remove(r)
        groups = self.root.find("groups")
        if groups is not None:
            for g in list(groups):
                members = [v for k, v in g.attrib.items() if re.fullmatch(r"member\d+", k)]
                if not members:
                    continue
                kept = [m for m in members if ok(m)]
                if len(kept) != len(members):
                    for k in [k for k in g.attrib if re.fullmatch(r"member\d+", k)]:
                        del g.attrib[k]
                    if not kept:
                        groups.remove(g)
                    for i, m in enumerate(kept):
                        g.set(f"member{i}", m)
        for t in self.iter_topics():
            if (t.get("summary1") and not ok(t.get("summary1"))) or (t.get("summary2") and not ok(t.get("summary2"))):
                t.attrib.pop("summary1", None)
                t.attrib.pop("summary2", None)

    def mapdata_bytes(self) -> bytes:
        # iThoughts writes no XML declaration; UTF-8 text, newline after each element.
        return serialize(self.root).encode("utf-8")

    def _refresh_manifest(self):
        raw = self.files.get("manifest.plist")
        try:
            m = plistlib.loads(raw) if raw else {}
        except Exception:
            m = {}
        topics = list(self.iter_topics())
        notes = [t.get("note") for t in topics if t.get("note")]
        words = lambda s: len((s or "").split())
        m.update({
            "Generated": _dt.datetime.now(_dt.timezone.utc).replace(tzinfo=None, microsecond=0),
            "MapRevision": new_uuid(),
            "TopicCount": len(topics),
            "TopicWordCount": sum(words(t.get("text")) for t in topics),
            "NoteCount": len(notes),
            "NoteWordCount": sum(words(n) for n in notes),
        })
        self.files["manifest.plist"] = plistlib.dumps(m, fmt=plistlib.FMT_XML)

    def to_bytes(self) -> bytes:
        self.files["mapdata.xml"] = self.mapdata_bytes()
        names = [n for n, _ in self.entries]
        for n in self.files:            # files added after load (e.g. manifest of new doc)
            if n not in names:
                names.append(n)
        if "mapdata.xml" in names:      # iThoughts puts mapdata.xml first
            names.remove("mapdata.xml")
            names.insert(0, "mapdata.xml")
        stamp = _dt.datetime.now().timetuple()[:6]
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            for n in names:
                zi = zipfile.ZipInfo(n, date_time=stamp)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = 0o600 << 16
                z.writestr(zi, self.files[n])
        return buf.getvalue()

    def save(self, path: str | None = None, backup_dir: str | None = None) -> str | None:
        """Atomically write the document. Returns backup path if one was made."""
        path = path or self.path
        if not path:
            raise ItmzError("no path to save to")
        data = self.to_bytes()
        ItmzDocument(data)  # sanity: our own output must re-open
        backup = None
        if backup_dir and os.path.exists(path):
            os.makedirs(backup_dir, exist_ok=True)
            base = os.path.basename(path)
            backup = os.path.join(backup_dir, f"{base[:-5]}.{_dt.datetime.now():%Y%m%d-%H%M%S}.itmz")
            shutil.copy2(path, backup)
        d = os.path.dirname(os.path.abspath(path))
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".itmz-", suffix=".tmp", dir=d)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.replace(tmp, path)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
        self.path = path
        return backup


_ATTR_ESC = str.maketrans({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;",
                           "\n": "&#10;", "\r": "&#13;", "\t": "&#9;"})
_TEXT_ESC = str.maketrans({"&": "&amp;", "<": "&lt;", ">": "&gt;"})
_BAD_XML_CHARS = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f]")


def serialize(el: ET.Element) -> str:
    """Serialise like iThoughts does (escaping incl. &apos; and &#10;)."""
    out: list[str] = []

    def w(e):
        attrs = "".join(f' {k}="{_BAD_XML_CHARS.sub("", v).translate(_ATTR_ESC)}"' for k, v in e.attrib.items())
        if len(e) == 0 and not e.text:
            out.append(f"<{e.tag}{attrs} />")
        else:
            out.append(f"<{e.tag}{attrs}>")
            if e.text:
                out.append(e.text.translate(_TEXT_ESC))
            for c in e:
                w(c)
            out.append(f"</{e.tag}>")
        if e.tail:
            out.append(e.tail.translate(_TEXT_ESC))
    w(el)
    return "".join(out)


_ATTR_HEAD = ("uuid", "position", "text")
_ATTR_TAIL = ("created", "modified")


def _canonical_attr_order(el: ET.Element):
    """Keep uuid/position/text first and created/modified last, like iThoughts."""
    a = el.attrib
    ordered = {k: a[k] for k in _ATTR_HEAD if k in a}
    ordered.update({k: v for k, v in a.items() if k not in _ATTR_HEAD and k not in _ATTR_TAIL})
    ordered.update({k: a[k] for k in _ATTR_TAIL if k in a})
    a.clear()
    a.update(ordered)


# ---------------------------------------------------------------- utilities
def walk(topics: list[dict], depth: int = 0, parent: dict | None = None):
    """Depth-first iterator over the JSON tree: yields (node, depth, parent)."""
    for t in topics:
        yield t, depth, parent
        yield from walk(t.get("children") or [], depth + 1, t)


def canonical_xml(raw: bytes) -> str:
    """Whitespace/attribute-order independent form, used by round-trip checks."""
    root = ET.fromstring(raw)

    def c(e):
        attrs = " ".join(f'{k}="{v}"' for k, v in sorted(e.attrib.items()))
        inner = "".join(c(x) for x in e)
        return f"<{e.tag} {attrs}>{inner}</{e.tag}>"
    return c(root)
