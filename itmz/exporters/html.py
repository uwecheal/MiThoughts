"""Self-contained HTML export.

Produces ONE .html file that contains the same viewer as the web app
(read-only: pan/zoom, fold/unfold, notes, links, search, outline) with the
map data and all attachments inlined as data: URIs.  Opens offline in any
browser, no server needed - ideal as a long-term archive format.
"""
from __future__ import annotations

import json
import os
import re

from .. import icons
from ..model import ItmzDocument
from .common import data_uri

EXT = ".html"
WEB_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "web")


def _read(name: str) -> str:
    with open(os.path.join(WEB_DIR, name), encoding="utf-8") as f:
        return f.read()


def _script_safe(s: str) -> str:
    return s.replace("</", "<\\/")


def render(doc: ItmzDocument, embed_assets: bool = True) -> str:
    payload = {
        "title": doc.title(),
        "map": doc.to_json(),
        "assets": {n: data_uri(n, doc.files[n]) for n in doc.asset_names()} if embed_assets else {},
        "icons": icons.as_json(),
        "readonly": True,
    }
    page = _read("index.html")
    page = re.sub(r"<title>.*?</title>", lambda m: f"<title>{_html_escape(doc.title())}</title>", page, count=1)
    page = page.replace('<link rel="stylesheet" href="app.css">', "<style>\n" + _read("app.css") + "\n</style>")
    inline = (f"<script>window.ITMZ_EMBED = {_script_safe(json.dumps(payload, ensure_ascii=False))};</script>\n"
              f"<script>\n{_script_safe(_read('md.js'))}\n</script>\n"
              f"<script>\n{_script_safe(_read('app.js'))}\n</script>")
    page = page.replace('<script src="md.js"></script>\n<script src="app.js"></script>', inline)
    return page


def _html_escape(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def export(doc: ItmzDocument, out_path: str) -> list[str]:
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(render(doc))
    return [out_path]
