import Foundation

enum ItmzLinks {
    private static let schemePattern = try! NSRegularExpression(pattern: "^[a-zA-Z][a-zA-Z0-9+.-]*:")
    private static let emailPattern = try! NSRegularExpression(pattern: "^[^@\\s/]+@[^@\\s/]+\\.[^@\\s/]+$")
    private static let domainPattern = try! NSRegularExpression(pattern: "^([\\w-]+(?:\\.[\\w-]+)+)(/\\S*)?$")
    private static let commonTopLevelDomains: Set<String> = ["com", "org", "net", "edu", "ch", "de", "uk", "io"]

    /// iThoughts stores links exactly as typed ("www.x.org", "me@x.org", "https://…").
    /// Returns an openable URL string; anything unrecognised is returned unchanged.
    static func normalize(_ link: String) -> String {
        let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(value.startIndex..., in: value)
        if schemePattern.firstMatch(in: value, range: range) != nil {
            return value
        }
        if emailPattern.firstMatch(in: value, range: range) != nil {
            return "mailto:" + value
        }
        if let match = domainPattern.firstMatch(in: value, range: range),
           let hostRange = Range(match.range(at: 1), in: value) {
            let host = String(value[hostRange])
            let hasPath = match.range(at: 2).location != NSNotFound
            let topLevel = host.split(separator: ".").last.map(String.init) ?? ""
            if value.hasPrefix("www.") || host.split(separator: ".").count > 2 || hasPath
                || commonTopLevelDomains.contains(topLevel.lowercased()) {
                return "http://" + value
            }
        }
        return value
    }
}
