import XCTest
@testable import ItmzKit

final class ItmzZipTests: XCTestCase {
    func testCRC32KnownValue() {
        XCTAssertEqual(ItmzCRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testZipRoundTripKeepsOrderAndContent() throws {
        var noise: [UInt8] = []
        var seed: UInt32 = 12345
        for _ in 0..<5000 {
            seed = seed &* 1_103_515_245 &+ 12345
            noise.append(UInt8(truncatingIfNeeded: seed >> 16))
        }
        let entries = [
            ItmzZipEntry(name: "mapdata.xml", data: Data(String(repeating: "<topic text=\"hello\" />\n", count: 200).utf8)),
            ItmzZipEntry(name: "empty.txt", data: Data()),
            ItmzZipEntry(name: "assets/ID/图片.bin", data: Data(noise)),
            ItmzZipEntry(name: "notes/x/small.txt", data: Data("a".utf8))
        ]
        let archive = try ItmzZip.write(entries)
        XCTAssertEqual(try ItmzZip.read(archive), entries)
    }

    func testRejectsNonZip() {
        XCTAssertThrowsError(try ItmzZip.read(Data("definitely not a zip file".utf8)))
    }
}

final class ItmzXMLTests: XCTestCase {
    func testByteIdenticalRoundTrip() throws {
        let source = "<iThoughts version=\"4.0\"><topics>\n"
            + "<topic uuid=\"1\" position=\"{0, 0}\" text=\"It&apos;s &amp; &lt;b&gt;\" note=\"a&#10;b\" created=\"x\" modified=\"y\">\n"
            + "<topic uuid=\"2\" position=\"{196, 0}\" text=\"中文\" created=\"x\" modified=\"y\">\n</topic>\n"
            + "</topic>\n</topics><relationships>\n"
            + "<relationship type=\"0\" uuid=\"R\" end1-uuid=\"1\" end2-uuid=\"2\" />\n"
            + "</relationships>\n</iThoughts>"
        let document = try ItmzXMLDocument(data: Data(source.utf8))
        XCTAssertEqual(document.serialized(), source)
        let topic = try XCTUnwrap(document.root.descendants(named: "topic").first)
        XCTAssertEqual(topic["text"], "It's & <b>")
        XCTAssertEqual(topic["note"], "a\nb")
    }

    func testPrologAndEpilogArePreserved() throws {
        let source = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- c --><a x='1'><b/></a>\n"
        let document = try ItmzXMLDocument(data: Data(source.utf8))
        XCTAssertEqual(document.prolog, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- c -->")
        XCTAssertEqual(document.epilog, "\n")
        XCTAssertEqual(document.serialized(), "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- c --><a x=\"1\"><b /></a>\n")
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try ItmzXMLDocument(data: Data("<a><b></a>".utf8)))
        XCTAssertThrowsError(try ItmzXMLDocument(data: Data("<a x=1/>".utf8)))
    }
}

final class ItmzDocumentTests: XCTestCase {
    /// A small map exercising notes, links, relationships, groups and an attachment.
    private func sampleDocument() throws -> ItmzDocument {
        let document = ItmzDocument.makeNew(title: "Root")
        var tree = document.topicTree()
        tree[0].children = [
            ItmzTopicNode(attributes: ["uuid": "A", "position": "{200, -40}",
                                       "text": "Alpha 'quoted' & <tag>", "note": "line1\nline2"],
                          children: [ItmzTopicNode(attributes: ["uuid": "A1", "position": "{150, 0}",
                                                                "text": "Alpha child", "link": "www.example.org"])]),
            ItmzTopicNode(attributes: ["uuid": "B", "position": "{-200, 40}", "text": "Beta",
                                       "color": "FFB2B2", "icon1": "idea"])
        ]
        try document.apply(tree)

        let relationships = try XCTUnwrap(document.root.firstChild(named: "relationships"))
        relationships.children.append(ItmzXMLElement(tag: "relationship", attributes: [
            .init(name: "type", value: "0"), .init(name: "uuid", value: "R1"),
            .init(name: "end1-uuid", value: "A1"), .init(name: "end2-uuid", value: "B"),
            .init(name: "center-text", value: "x")
        ], tail: "\n"))
        document.root.children.append(ItmzXMLElement(tag: "groups", children: [
            ItmzXMLElement(tag: "group", attributes: [
                .init(name: "type", value: "0"), .init(name: "member0", value: "A"), .init(name: "member1", value: "B")
            ])
        ]))

        var entries = try ItmzZip.read(document.archiveData())
        entries.append(ItmzZipEntry(name: "notes/A/pic.png", data: Data([0x89, 0x50, 0x4E, 0x47])))
        return try ItmzDocument(data: ItmzZip.write(entries))
    }

    private func texts(_ topics: [ItmzTopicNode]) -> [String] {
        topics.flatMap { [$0.attributes["text"] ?? ""] + texts($0.children) }
    }

    func testNewDocumentReopens() throws {
        let document = try ItmzDocument(data: ItmzDocument.makeNew(title: "Hello").archiveData())
        XCTAssertEqual(document.title, "Hello")
        XCTAssertEqual(try ItmzZip.read(document.archiveData()).first?.name, "mapdata.xml")
    }

    func testEscapingMatchesIThoughts() throws {
        let xml = String(decoding: try sampleDocument().mapDataBytes(), as: UTF8.self)
        XCTAssertTrue(xml.contains("text=\"Alpha &apos;quoted&apos; &amp; &lt;tag&gt;\""))
        XCTAssertTrue(xml.contains("note=\"line1&#10;line2\""))
        XCTAssertFalse(xml.hasPrefix("<?xml"))
    }

    func testNoOpApplyIsLossless() throws {
        let document = try sampleDocument()
        let before = try ItmzXMLDocument(data: document.mapDataBytes()).root
        try document.apply(document.topicTree())
        let after = try ItmzXMLDocument(data: document.mapDataBytes()).root
        before["modified"] = nil
        after["modified"] = nil
        XCTAssertEqual(canonical(before), canonical(after))
    }

    func testEditAddMoveDelete() throws {
        let document = try sampleDocument()
        var tree = document.topicTree()
        var alpha = tree[0].children[0]
        var beta = tree[0].children[1]
        alpha.attributes["text"] = "Alpha edited"
        alpha.attributes["unknown-attr-from-ui"] = "ignored"
        let alphaChild = alpha.children.removeLast()
        beta.children.append(alphaChild)                                                     // move A1 under B
        beta.children.append(ItmzTopicNode(attributes: ["position": "{100, 0}", "text": "new"])) // create
        tree[0].children = [beta]                                                             // delete A

        let report = try document.apply(tree)
        XCTAssertEqual(report.created, 1)
        XCTAssertEqual(report.deleted, 1)
        XCTAssertEqual(report.moved, 1)

        let reopened = try ItmzDocument(data: document.archiveData())
        XCTAssertEqual(texts(reopened.topicTree()), ["Root", "Beta", "Alpha child", "new"])
        XCTAssertEqual(reopened.relationships.count, 1)                        // A1 -> B survives
        let expectedGroup = [ItmzXMLAttribute(name: "type", value: "0"), ItmzXMLAttribute(name: "member0", value: "B")]
        XCTAssertEqual(reopened.groups.first?.attributes ?? [], expectedGroup)
        XCTAssertFalse(String(decoding: reopened.mapDataBytes(), as: UTF8.self).contains("unknown-attr-from-ui"))
        XCTAssertNotNil(reopened.file(named: "notes/A/pic.png"))              // attachments preserved
    }

    func testDanglingRelationshipIsRemoved() throws {
        let document = try sampleDocument()
        var tree = document.topicTree()
        tree[0].children.removeLast() // delete B
        try document.apply(tree)
        XCTAssertTrue(document.relationships.isEmpty)
    }

    func testDuplicateUUIDIsRejected() throws {
        let document = try sampleDocument()
        var tree = document.topicTree()
        tree[0].children.append(tree[0].children[0])
        XCTAssertThrowsError(try document.apply(tree))
    }

    func testSaveIsAtomicAndBacksUp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ItmzKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("map.itmz")

        try sampleDocument().save(to: url)
        let document = try ItmzDocument(contentsOf: url)
        let backup = try document.save(backupDirectory: folder.appendingPathComponent("backups"))
        XCTAssertNotNil(backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup?.path ?? ""))
        XCTAssertNotNil(try ItmzDocument(contentsOf: url).file(named: "notes/A/pic.png"))
    }

    func testBadFilesAreRejected() throws {
        XCTAssertThrowsError(try ItmzDocument(data: Data("not a zip".utf8)))
        let noMap = try ItmzZip.write([ItmzZipEntry(name: "other.xml", data: Data("<x/>".utf8))])
        XCTAssertThrowsError(try ItmzDocument(data: noMap)) { error in
            XCTAssertEqual(error as? ItmzError, .missingMapData)
        }
    }

    func testPositionFormatting() {
        XCTAssertEqual(ItmzFormat.formatPosition(x: 196, y: -0.0000001), "{196, 0}")
        XCTAssertEqual(ItmzFormat.formatPosition(x: 12.5, y: -787.639360), "{12.5, -787.63936}")
        XCTAssertEqual(ItmzFormat.parsePosition("{287, -787.63936089847448}").y, -787.63936089847448, accuracy: 1e-9)
    }

    func testLinkNormalisation() {
        XCTAssertEqual(ItmzLinks.normalize("www.ithoughts.co.uk/x"), "http://www.ithoughts.co.uk/x")
        XCTAssertEqual(ItmzLinks.normalize("support@ithoughts.co.uk"), "mailto:support@ithoughts.co.uk")
        XCTAssertEqual(ItmzLinks.normalize("https://a.b"), "https://a.b")
        XCTAssertEqual(ItmzLinks.normalize("scg.unibe.ch/x"), "http://scg.unibe.ch/x")
        XCTAssertEqual(ItmzLinks.normalize("example.com"), "http://example.com")
        XCTAssertEqual(ItmzLinks.normalize("foo.md"), "foo.md")
    }

    /// Opt-in: ITMZ_SAMPLES=~/Desktop/iThoughts-main swift test
    func testRealSamplesRoundTripByteIdentical() throws {
        guard let folder = ProcessInfo.processInfo.environment["ITMZ_SAMPLES"] else {
            throw XCTSkip("set ITMZ_SAMPLES=/folder/with/maps to run against real files")
        }
        let root = URL(fileURLWithPath: NSString(string: folder).expandingTildeInPath)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var count = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "itmz" else {
                continue
            }
            let document = try ItmzDocument(contentsOf: url)
            XCTAssertEqual(document.file(named: "mapdata.xml"), document.mapDataBytes(), url.lastPathComponent)
            let before = try ItmzXMLDocument(data: document.mapDataBytes()).root
            try document.apply(document.topicTree())
            let reopened = try ItmzDocument(data: document.archiveData())
            let after = reopened.root
            before["modified"] = nil
            after["modified"] = nil
            XCTAssertEqual(canonical(before), canonical(after), url.lastPathComponent)
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
    }
}

/// Whitespace- and attribute-order-independent form of an element.
func canonical(_ element: ItmzXMLElement) -> String {
    let attributes = element.attributes
        .sorted { $0.name < $1.name }
        .map { "\($0.name)=\"\($0.value)\"" }
        .joined(separator: " ")
    return "<\(element.tag) \(attributes)>" + element.children.map(canonical).joined() + "</\(element.tag)>"
}
