"""Run:  python3 -m unittest discover -s tests -v
Optional: ITMZ_SAMPLES=/path/to/maps also round-trips every real .itmz there."""
import io
import os
import sys
import tempfile
import unittest
import zipfile
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from itmz.model import ItmzDocument, ItmzError, canonical_xml, serialize, walk  # noqa: E402
from itmz.exporters import EXPORTERS  # noqa: E402


def sample_doc():
    """A small map exercising notes, links, relationships, groups, attachments."""
    doc = ItmzDocument.new("Root")
    data = doc.to_json()
    root = data["topics"][0]
    root["children"] = [
        {"attrs": {"uuid": "A", "position": "{200, -40}", "text": "Alpha 'quoted' & <tag>", "note": "line1\nline2"}, "children": [
            {"attrs": {"uuid": "A1", "position": "{150, 0}", "text": "Alpha child", "link": "www.example.org"}, "children": []}]},
        {"attrs": {"uuid": "B", "position": "{-200, 40}", "text": "Beta", "color": "FFB2B2", "icon1": "idea"}, "children": []},
    ]
    doc.apply_json(data)
    rels = doc.root.find("relationships")
    ET.SubElement(rels, "relationship", {"type": "0", "uuid": "R1", "end1-uuid": "A1", "end2-uuid": "B", "center-text": "x"}).tail = "\n"
    groups = ET.SubElement(doc.root, "groups")
    ET.SubElement(groups, "group", {"type": "0", "member0": "A", "member1": "B"})
    doc.files["notes/A/pic.png"] = b"\x89PNG fake"
    doc.entries.append(("notes/A/pic.png", doc.files["notes/A/pic.png"]))
    return ItmzDocument(doc.to_bytes())


class ModelTests(unittest.TestCase):
    def test_new_and_reopen(self):
        doc = ItmzDocument(ItmzDocument.new("Hello").to_bytes())
        self.assertEqual(doc.title(), "Hello")
        self.assertEqual(zipfile.ZipFile(io.BytesIO(doc.to_bytes())).namelist()[0], "mapdata.xml")

    def test_escaping_matches_ithoughts(self):
        doc = sample_doc()
        xml = doc.mapdata_bytes().decode()
        self.assertIn('text="Alpha &apos;quoted&apos; &amp; &lt;tag&gt;"', xml)
        self.assertIn('note="line1&#10;line2"', xml)
        self.assertFalse(xml.startswith("<?xml"))

    def test_noop_roundtrip_is_lossless(self):
        doc = sample_doc()
        before = doc.mapdata_bytes()
        doc.apply_json(doc.to_json())
        a, b = ET.fromstring(before), ET.fromstring(doc.mapdata_bytes())
        a.attrib.pop("modified"); b.attrib.pop("modified")
        self.assertEqual(canonical_xml(ET.tostring(a)), canonical_xml(ET.tostring(b)))

    def test_edit_add_move_delete(self):
        doc = sample_doc()
        data = doc.to_json()
        root = data["topics"][0]
        alpha, beta = root["children"]
        alpha["attrs"]["text"] = "Alpha edited"
        alpha["attrs"]["unknown-attr-from-ui"] = "ignored"
        beta["children"].append(alpha["children"].pop())           # move A1 under B
        beta["children"].append({"attrs": {"position": "{100, 0}", "text": "new"}, "children": []})
        root["children"] = [beta]                                    # delete A
        rep = doc.apply_json(data)
        self.assertEqual((rep["created"], rep["deleted"], rep["moved"]), (1, 1, 1))
        doc2 = ItmzDocument(doc.to_bytes())
        texts = [n["attrs"].get("text") for n, _, _ in walk(doc2.to_json()["topics"])]
        self.assertEqual(texts, ["Root", "Beta", "Alpha child", "new"])
        # relationship A1->B survives, group with deleted member A is reduced to one member
        self.assertEqual(len(doc2.to_json()["relationships"]), 1)
        self.assertEqual(doc2.to_json()["groups"], [{"type": "0", "member0": "B"}])
        # unknown attrs from the UI are not written
        self.assertNotIn("unknown-attr-from-ui", doc2.mapdata_bytes().decode())
        # untouched topic keeps its timestamp, edited ones get a new one
        b = [n for n, _, _ in walk(doc2.to_json()["topics"]) if n["attrs"]["uuid"] == "B"][0]
        self.assertIn("modified", b["attrs"])

    def test_dangling_relationship_removed(self):
        doc = sample_doc()
        data = doc.to_json()
        data["topics"][0]["children"][1]["children"] = []
        data["topics"][0]["children"].pop()                         # delete B
        doc.apply_json(data)
        self.assertEqual(doc.to_json()["relationships"], [])

    def test_duplicate_uuid_rejected(self):
        doc = sample_doc()
        data = doc.to_json()
        data["topics"][0]["children"].append(data["topics"][0]["children"][0])
        with self.assertRaises(ItmzError):
            doc.apply_json(data)

    def test_save_backup_and_atomic(self):
        with tempfile.TemporaryDirectory() as td:
            p = os.path.join(td, "m.itmz")
            sample_doc().save(p)
            doc = ItmzDocument.load(p)
            backup = doc.save(backup_dir=os.path.join(td, "bk"))
            self.assertTrue(os.path.exists(backup))
            self.assertIn("notes/A/pic.png", ItmzDocument.load(p).files)   # attachments preserved

    def test_bad_files(self):
        with self.assertRaises(ItmzError):
            ItmzDocument(b"not a zip")
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("other.xml", "<x/>")
        with self.assertRaises(ItmzError):
            ItmzDocument(buf.getvalue())


class ExportTests(unittest.TestCase):
    def test_all_exporters(self):
        doc = sample_doc()
        with tempfile.TemporaryDirectory() as td:
            for fmt, mod in EXPORTERS.items():
                out = os.path.join(td, "m" + mod.EXT)
                written = mod.export(doc, out)
                self.assertTrue(os.path.getsize(out) > 0, fmt)
                if fmt in ("opml", "mm"):
                    ET.parse(out)                                   # well-formed XML
            md = open(os.path.join(td, "m.md"), encoding="utf-8").read()
            self.assertIn("# Root", md)
            self.assertIn("http://www.example.org", md)
            self.assertIn("Alpha child → Beta", md)
            self.assertIn("💡", md)
            html = open(os.path.join(td, "m.html"), encoding="utf-8").read()
            self.assertIn("window.ITMZ_EMBED", html)
            self.assertNotIn('<script src="app.js">', html)


@unittest.skipUnless(os.environ.get("ITMZ_SAMPLES"), "set ITMZ_SAMPLES=/folder/with/maps")
class RealSampleTests(unittest.TestCase):
    def test_every_sample_roundtrips_byte_identical(self):
        n = 0
        for dirpath, _, files in os.walk(os.environ["ITMZ_SAMPLES"]):
            for f in files:
                if f.endswith(".itmz"):
                    doc = ItmzDocument.load(os.path.join(dirpath, f))
                    self.assertEqual(doc.files["mapdata.xml"], serialize(doc.root).encode(), f)
                    n += 1
        self.assertGreater(n, 0)


if __name__ == "__main__":
    unittest.main()
