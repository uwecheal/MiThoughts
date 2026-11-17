"""Exporter registry.  To add a format: create a module with EXT and
export(doc, out_path) -> list[str], then register it here."""
from . import freemind, html, jsonx, markdown, opml

EXPORTERS = {
    "md": markdown,
    "opml": opml,
    "html": html,
    "mm": freemind,
    "json": jsonx,
}
