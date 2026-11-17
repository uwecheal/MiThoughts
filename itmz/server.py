"""Local web server: serves web/ and a small JSON API over one folder of maps.

Binds to 127.0.0.1 only.  Write requests need a custom header (blocks
cross-site form posts) and the Host header is checked (blocks DNS
rebinding), so other web pages you visit cannot touch your files.
"""
from __future__ import annotations

import io
import json
import mimetypes
import os
import tempfile
import threading
import urllib.parse
import webbrowser
import zipfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import __version__, icons
from .exporters import EXPORTERS
from .model import ItmzDocument, ItmzError

WEB_DIR = Path(__file__).resolve().parent.parent / "web"
BACKUP_DIRNAME = ".itmz-studio-backups"
ICON_CANDIDATES = (
    "Contents/Resources/topic-icons",                       # app bundle contents copied next to maps
    "/Applications/iThoughtsX.app/Contents/Resources/topic-icons",
    "~/Applications/iThoughtsX.app/Contents/Resources/topic-icons",
)


def find_icons_dir(root: Path, explicit: str | None) -> Path | None:
    cands = [explicit] if explicit else ICON_CANDIDATES
    for c in cands:
        p = Path(os.path.expanduser(c))
        if not p.is_absolute():
            p = root / p
        if p.is_dir():
            return p
    return None


def list_maps(root: Path) -> list[dict]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and not d.endswith(".assets"))
        for fn in sorted(filenames):
            if fn.lower().endswith(".itmz") and not fn.startswith("."):
                p = Path(dirpath) / fn
                st = p.stat()
                out.append({"path": p.relative_to(root).as_posix(), "size": st.st_size, "mtime": st.st_mtime})
    return out


class ApiError(Exception):
    def __init__(self, status: int, msg: str):
        super().__init__(msg)
        self.status = status


class App:
    def __init__(self, root: str, icons_dir: str | None = None):
        self.root = Path(root).expanduser().resolve()
        if not self.root.is_dir():
            raise SystemExit(f"not a folder: {self.root}")
        self.icons_dir = find_icons_dir(self.root, icons_dir)
        self.backup_dir = self.root / BACKUP_DIRNAME
        self.lock = threading.Lock()

    def resolve(self, rel: str, must_exist: bool = True) -> Path:
        if not rel:
            raise ApiError(400, "missing path")
        p = (self.root / rel).resolve()
        if p != self.root and self.root not in p.parents:
            raise ApiError(403, "path outside the map folder")
        if p.suffix.lower() != ".itmz":
            raise ApiError(400, "only .itmz files")
        if must_exist and not p.is_file():
            raise ApiError(404, f"no such map: {rel}")
        return p

    def rel(self, p: Path) -> str:
        return p.relative_to(self.root).as_posix()

    def rel_backup(self, p: str) -> str:
        return os.path.relpath(p, self.root)


def _mtime(p: Path) -> str:
    return str(p.stat().st_mtime_ns)


def make_handler(app: App, port: int):
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}", f"[::1]:{port}"}

    class Handler(BaseHTTPRequestHandler):
        server_version = f"itmz-studio/{__version__}"

        def log_message(self, fmt, *args):  # quiet unless error
            if args and str(args[1])[:1] in "45":
                super().log_message(fmt, *args)

        # ------------------------------------------------ plumbing
        def _send(self, status, body: bytes, ctype: str, extra: dict | None = None):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, obj, status=200):
            self._send(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

        def _guard(self, write: bool):
            if self.headers.get("Host") not in allowed_hosts:
                raise ApiError(403, "bad Host header")
            if write and self.headers.get("X-Itmz") != "1":
                raise ApiError(403, "missing X-Itmz header")

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 200 * 1024 * 1024:
                raise ApiError(413, "request too large")
            try:
                return json.loads(self.rfile.read(n) or b"{}")
            except json.JSONDecodeError as e:
                raise ApiError(400, f"bad JSON: {e}")

        def _dispatch(self, write: bool):
            url = urllib.parse.urlsplit(self.path)
            q = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
            try:
                self._guard(write)
                if url.path.startswith("/api/"):
                    fn = getattr(self, ("post_" if write else "get_") + url.path[5:].replace("/", "_"), None)
                    if fn is None:
                        raise ApiError(404, "unknown endpoint")
                    fn(q)
                elif not write:
                    self.static(url.path)
                else:
                    raise ApiError(404, "not found")
            except ApiError as e:
                self._json({"error": str(e)}, e.status)
            except ItmzError as e:
                self._json({"error": f"bad map file: {e}"}, 422)
            except Exception as e:  # pragma: no cover - surfaced to UI
                self.log_error("internal error: %r", e)
                self._json({"error": f"internal error: {e}"}, 500)

        def do_GET(self):
            self._dispatch(False)

        def do_POST(self):
            self._dispatch(True)

        # ------------------------------------------------ static
        def static(self, path):
            rel = urllib.parse.unquote(path).lstrip("/") or "index.html"
            p = (WEB_DIR / rel).resolve()
            if WEB_DIR not in p.parents or not p.is_file():
                raise ApiError(404, "not found")
            ctype = mimetypes.guess_type(p.name)[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype.endswith("javascript"):
                ctype += "; charset=utf-8"
            self._send(200, p.read_bytes(), ctype)

        # ------------------------------------------------ GET api
        def get_info(self, q):
            self._json({"version": __version__, "root": str(app.root),
                        "iconsDir": str(app.icons_dir) if app.icons_dir else None,
                        "icons": icons.as_json(), "exporters": list(EXPORTERS)})

        def get_files(self, q):
            self._json({"root": str(app.root), "files": list_maps(app.root)})

        def get_map(self, q):
            p = app.resolve(q.get("path"))
            doc = ItmzDocument.load(str(p))
            self._json({"path": app.rel(p), "mtime": _mtime(p), "map": doc.to_json()})

        def get_file(self, q):
            p = app.resolve(q.get("path"))
            name = q.get("name", "")
            if not (name.startswith(("assets/", "notes/")) or name == "preview.png"):
                raise ApiError(403, "only attachments can be fetched")
            data = ItmzDocument.load(str(p)).read_file(name)
            if data is None:
                raise ApiError(404, "attachment not in archive")
            ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
            extra = {"Cache-Control": "private, max-age=300"}
            if not ctype.startswith("image/") or ctype == "image/svg+xml":
                # never let attachments run script in our origin
                extra["Content-Security-Policy"] = "sandbox"
            self._send(200, data, ctype, extra)

        def get_icon(self, q):
            if not app.icons_dir:
                raise ApiError(404, "no icon folder configured")
            fn = icons.file_name(q.get("name", ""))
            p = (app.icons_dir / fn).resolve()
            if app.icons_dir not in p.parents or not p.is_file():
                raise ApiError(404, "icon not found")
            self._send(200, p.read_bytes(), "image/png", {"Cache-Control": "max-age=86400"})

        def get_export(self, q):
            p = app.resolve(q.get("path"))
            fmt = q.get("fmt", "md")
            if fmt not in EXPORTERS:
                raise ApiError(400, f"unknown format {fmt}")
            mod = EXPORTERS[fmt]
            doc = ItmzDocument.load(str(p))
            with tempfile.TemporaryDirectory() as td:
                out = Path(td) / (p.stem + mod.EXT)
                written = [Path(w) for w in mod.export(doc, str(out))]
                if len(written) == 1:
                    body, name = out.read_bytes(), out.name
                    ctype = mimetypes.guess_type(out.name)[0] or "application/octet-stream"
                else:  # file + attachments folder -> zip
                    buf = io.BytesIO()
                    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
                        for w in written:
                            z.write(w, w.relative_to(td).as_posix())
                    body, name, ctype = buf.getvalue(), f"{p.stem}{mod.EXT}.zip", "application/zip"
            disp = "attachment; filename*=UTF-8''" + urllib.parse.quote(name)
            self._send(200, body, ctype, {"Content-Disposition": disp})

        # ------------------------------------------------ POST api
        def post_save(self, q):
            b = self._body()
            src = app.resolve(b.get("path"))
            dest = app.resolve(b["saveAs"], must_exist=False) if b.get("saveAs") else src
            with app.lock:
                if dest == src and not b.get("force") and b.get("mtime") and b["mtime"] != _mtime(src):
                    raise ApiError(409, "file was changed on disk since it was opened")
                if dest != src and dest.exists() and not b.get("force"):
                    raise ApiError(409, "target file already exists")
                doc = ItmzDocument.load(str(src))
                report = doc.apply_json({"topics": b.get("topics")})
                backup = doc.save(str(dest), str(app.backup_dir) if dest.exists() else None)
            self._json({"ok": True, "path": app.rel(dest), "mtime": _mtime(dest), "report": report,
                        "backup": app.rel_backup(backup) if backup else None})

        def post_new(self, q):
            b = self._body()
            dest = app.resolve(b.get("path"), must_exist=False)
            if dest.exists():
                raise ApiError(409, "file already exists")
            ItmzDocument.new(b.get("title") or dest.stem).save(str(dest))
            self._json({"ok": True, "path": app.rel(dest)})

    return Handler


def serve(root: str, host: str = "127.0.0.1", port: int = 8765, icons_dir: str | None = None, open_browser=True):
    app = App(root, icons_dir)
    httpd = ThreadingHTTPServer((host, port), make_handler(app, port))
    url = f"http://127.0.0.1:{port}/"
    print(f"itmz-studio {__version__}")
    print(f"  maps folder : {app.root}")
    print(f"  icons       : {app.icons_dir or '(none found - using emoji)'}")
    print(f"  backups     : {app.backup_dir}")
    print(f"  open        : {url}   (Ctrl+C to stop)")
    if open_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
    finally:
        httpd.server_close()
