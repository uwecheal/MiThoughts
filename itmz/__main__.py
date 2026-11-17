"""Command line:  python3 -m itmz <command> ...

  serve  [FOLDER]                 start the local web app (default command)
  export SRC... -f md,opml,html   batch export, mirrors folder structure
  check  SRC...                   verify every map parses and re-saves losslessly
  info   FILE                     print statistics about one map
  new    FILE [--title T]         create an empty map
"""
from __future__ import annotations

import argparse
import os
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

from . import __version__
from .exporters import EXPORTERS
from .model import ItmzDocument, ItmzError, canonical_xml, walk


def collect(sources: list[str]) -> list[tuple[Path, Path]]:
    """-> [(file, base folder for relative output paths)]"""
    out = []
    for s in sources:
        p = Path(s).expanduser()
        if p.is_dir():
            for dirpath, dirnames, filenames in os.walk(p):
                dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and not d.endswith(".assets"))
                out += [(Path(dirpath) / f, p) for f in sorted(filenames) if f.lower().endswith(".itmz")]
        elif p.is_file():
            out.append((p, p.parent))
        else:
            print(f"warning: {s} not found", file=sys.stderr)
    return out


def cmd_export(a):
    fmts = [f.strip() for f in a.format.split(",") if f.strip()]
    bad = [f for f in fmts if f not in EXPORTERS]
    if bad:
        sys.exit(f"unknown format(s): {', '.join(bad)}; choose from {', '.join(EXPORTERS)}")
    files = collect(a.sources)
    out_root = Path(a.out).expanduser()
    ok = fail = 0
    t0 = time.time()
    for f, base in files:
        rel = f.relative_to(base).with_suffix("")
        try:
            doc = ItmzDocument.load(str(f))
            for fmt in fmts:
                mod = EXPORTERS[fmt]
                dest = out_root / (rel.as_posix() + mod.EXT)
                if dest.exists() and not a.overwrite:
                    continue
                dest.parent.mkdir(parents=True, exist_ok=True)
                mod.export(doc, str(dest))
            ok += 1
            if a.verbose:
                print(f"  ok   {rel}")
        except Exception as e:  # keep going - one bad file must not stop a batch
            fail += 1
            print(f"  FAIL {f}: {e}", file=sys.stderr)
    print(f"exported {ok} map(s) as {', '.join(fmts)} to {out_root}  ({fail} failed, {time.time() - t0:.1f}s)")
    return 1 if fail else 0


def cmd_check(a):
    files = collect(a.sources)
    bad = 0
    for f, _ in files:
        try:
            doc = ItmzDocument.load(str(f))
            before = ET.fromstring(doc.files["mapdata.xml"])
            doc.apply_json(doc.to_json())
            after = ItmzDocument(doc.to_bytes()).root
            before.attrib.pop("modified", None)
            after.attrib.pop("modified", None)
            if canonical_xml(ET.tostring(before)) != canonical_xml(ET.tostring(after)):
                raise ItmzError("round trip changed the map")
        except Exception as e:
            bad += 1
            print(f"  FAIL {f}: {e}")
    print(f"checked {len(files)} map(s): {len(files) - bad} ok, {bad} problem(s)")
    return 1 if bad else 0


def cmd_info(a):
    doc = ItmzDocument.load(a.file)
    data = doc.to_json()
    nodes = list(walk(data["topics"]))
    print(f"file        : {a.file}")
    print(f"title       : {doc.title()}")
    print(f"written by  : {data['meta'].get('app')} {data['meta'].get('app-version')} on {data['meta'].get('author')}")
    print(f"modified    : {data['meta'].get('modified')}")
    print(f"topics      : {len(nodes)} (max depth {max(d for _, d, _ in nodes)})")
    print(f"notes/links : {sum(1 for n, _, _ in nodes if n['attrs'].get('note'))} / "
          f"{sum(1 for n, _, _ in nodes if n['attrs'].get('link'))}")
    print(f"relations   : {len(data['relationships'])}   groups: {len(data['groups'])}")
    print(f"attachments : {len(data['files'])}")
    for name, _ in doc.entries:
        print(f"   {len(doc.files[name]):>9}  {name}")


def cmd_new(a):
    if os.path.exists(a.file):
        sys.exit("file exists")
    ItmzDocument.new(a.title or Path(a.file).stem).save(a.file)
    print(f"created {a.file}")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="itmz", description=f"itmz-studio {__version__} - iThoughts .itmz toolkit")
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("serve", help="start the local web app")
    s.add_argument("folder", nargs="?", default=".")
    s.add_argument("--port", type=int, default=8765)
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--icons", help="folder with iThoughts topic-icons PNGs (optional)")
    s.add_argument("--no-browser", action="store_true")
    e = sub.add_parser("export", help="batch export maps")
    e.add_argument("sources", nargs="+")
    e.add_argument("-f", "--format", default="md,opml,html", help=f"comma list of {','.join(EXPORTERS)}")
    e.add_argument("-o", "--out", default="export")
    e.add_argument("--overwrite", action="store_true")
    e.add_argument("-v", "--verbose", action="store_true")
    c = sub.add_parser("check", help="verify maps parse and re-save losslessly")
    c.add_argument("sources", nargs="+")
    i = sub.add_parser("info", help="show statistics of a map")
    i.add_argument("file")
    n = sub.add_parser("new", help="create an empty map")
    n.add_argument("file")
    n.add_argument("--title")
    a = ap.parse_args(argv)
    if a.cmd in (None, "serve"):
        from .server import serve
        if a.cmd is None:
            a = ap.parse_args(["serve", *(argv or [])])
        serve(a.folder, a.host, a.port, a.icons, not a.no_browser)
        return 0
    return {"export": cmd_export, "check": cmd_check, "info": cmd_info, "new": cmd_new}[a.cmd](a) or 0


if __name__ == "__main__":
    sys.exit(main())
