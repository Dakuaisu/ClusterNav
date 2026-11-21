import Foundation

/// A destination extracted from a shared map link or text.
public enum MapLinkResult: Sendable, Equatable {
    case place(Coordinate, name: String?)
    /// A shortened link (e.g. maps.app.goo.gl) that must be expanded by following
    /// its redirect before it can be parsed.
    case needsExpansion(URL)
}

/// Reads destinations from what other apps share: Apple Maps and Google Maps links,
/// `geo:` URIs, WhatsApp location messages, plain `lat,lng` and full plus codes.
/// Nothing is looked up online except expanding short links (done by the caller).
public enum MapLinkParser {
    static let shortLinkHosts: Set<String> = ["maps.app.goo.gl", "goo.gl", "g.co", "maps.apple"]

    /// Google's own domains only, with proper label boundaries: `maps.google.co.in`
    /// passes, `google.evil.com` and `notgoogle.com` do not.
    public static func isGoogleHost(_ host: String) -> Bool {
        host.lowercased().wholeMatch(of: /([a-z0-9-]+\.)*google\.(com|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})/) != nil
    }

    public static func isAppleMapsHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "maps.apple.com" || host.hasSuffix(".maps.apple.com") || host == "maps.apple"
    }

    public static func isShortLinkHost(_ host: String) -> Bool {
        shortLinkHosts.contains(host.lowercased())
    }

    /// Shared text longer than this is not parsed at all.
    public static let maxInputBytes = 4 * 1_024

    public static func parse(_ text: String) -> MapLinkResult? {
        guard text.utf8.count <= maxInputBytes else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for url in urls(in: trimmed) {
            if let result = parse(url: url) { return result }
        }
        // A link that named no destination is never mined for some other coordinate
        // (an origin, a map centre): only the words around it are read as plain text.
        let words = trimmed.split(whereSeparator: \.isWhitespace).filter { url(from: $0) == nil }
        let plain = words.joined(separator: " ")
        if case .success(let coordinate) = DestinationInputParser.parse(plain) {
            return .place(coordinate, name: nil)
        }
        // Not part of a longer number: "112.9716, 77.5946" is a typo, not 12.9716.
        if let match = plain.firstMatch(of: /(?:^|[^\d.])(-?\d{1,2}\.\d{3,})\s*,\s*(-?\d{1,3}\.\d{3,})/),
           let coordinate = coordinate(String(match.1), String(match.2)) {
            return .place(coordinate, name: nil)
        }
        for token in words where token.contains("+") {
            if OpenLocationCode.isFull(String(token)),
               case .success(let coordinate) = DestinationInputParser.parse(String(token)) {
                return .place(coordinate, name: nil)
            }
        }
        return nil
    }

    public static func parse(url: URL) -> MapLinkResult? {
        if url.scheme?.lowercased() == "geo" { return geo(url) }
        guard let host = url.host?.lowercased() else { return nil }
        if shortLinkHosts.contains(host) || (host == "goo.gl" && url.path.hasPrefix("/maps")) {
            return .needsExpansion(url)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name.lowercased(), $0) }
        }, uniquingKeysWith: { first, _ in first })

        if isAppleMapsHost(host) {
            let name = query["q"].flatMap { coordinateText($0) == nil ? $0 : nil }
            // Directions: only the stated destination counts. `ll` is then the map centre.
            if let destination = query["daddr"] {
                return coordinateText(destination).map { .place($0, name: name) }
            }
            // `sll` is where a search was centred, not a place: never a destination.
            for key in ["coordinate", "ll", "q"] {
                if let value = query[key], let coordinate = coordinateText(value) {
                    return .place(coordinate, name: name)
                }
            }
            return nil
        }

        if isGoogleHost(host) {
            // Directions: only the stated destination counts, never the origin, a
            // waypoint or the camera position.
            if let destination = query["destination"] ?? query["daddr"] {
                return coordinateText(destination).map { .place($0, name: nil) }
            }
            let path = url.pathComponents
            if let index = path.firstIndex(of: "dir") {
                let stops = path[(index + 1)...].filter { !$0.hasPrefix("@") && !$0.hasPrefix("data=") }
                return stops.count >= 2 ? stops.last.flatMap(coordinateText).map { .place($0, name: nil) } : nil
            }
            // A search is centred on the camera, which is not a place either.
            if path.contains("search"), query["query"].flatMap(coordinateText) == nil { return nil }
            if let match = url.absoluteString.firstMatch(of: /!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)/),
               let coordinate = coordinate(String(match.1), String(match.2)) {
                return .place(coordinate, name: googlePlaceName(url))
            }
            for key in ["q", "query", "ll", "center"] {
                if let value = query[key], let coordinate = coordinateText(value) {
                    return .place(coordinate, name: googlePlaceName(url))
                }
            }
            if let match = url.absoluteString.firstMatch(of: /@(-?\d+\.\d+),(-?\d+\.\d+)/),
               let coordinate = coordinate(String(match.1), String(match.2)) {
                return .place(coordinate, name: googlePlaceName(url))
            }
        }
        return nil
    }

    /// `geo:12.97,77.59` or `geo:0,0?q=12.97,77.59(Office)`.
    private static func geo(_ url: URL) -> MapLinkResult? {
        let body = String(url.absoluteString.dropFirst("geo:".count))
        let parts = body.split(separator: "?", maxSplits: 1).map(String.init)
        let q = parts.count > 1
            ? URLComponents(string: "x:?" + parts[1])?.queryItems?.first { $0.name == "q" }?.value : nil
        let name = q.flatMap { $0.firstMatch(of: /\(([^)]+)\)/).map { String($0.1) } }
        let point = parts.first?.split(separator: ";").first.map(String.init) ?? ""
        if let coordinate = coordinateText(point), coordinate.latitude != 0 || coordinate.longitude != 0 {
            return .place(coordinate, name: name)
        }
        if let q, let coordinate = coordinateText(q) { return .place(coordinate, name: name) }
        return nil
    }

    private static func googlePlaceName(_ url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "place"), index + 1 < parts.count else { return nil }
        let raw = parts[index + 1].replacingOccurrences(of: "+", with: " ")
        let name = raw.removingPercentEncoding ?? raw
        return name.isEmpty || coordinateText(name) != nil ? nil : name
    }

    /// "12.97,77.59" possibly followed by "(Label)" or other text.
    public static func coordinateText(_ value: String) -> Coordinate? {
        guard let match = value.firstMatch(of: /^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)/) else { return nil }
        return coordinate(String(match.1), String(match.2))
    }

    private static func coordinate(_ lat: String, _ lng: String) -> Coordinate? {
        guard let latitude = Double(lat), let longitude = Double(lng) else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    private static func urls(in text: String) -> [URL] {
        text.split(whereSeparator: \.isWhitespace).compactMap(url(from:))
    }

    private static func url(from token: Substring) -> URL? {
        var candidate = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        if candidate.hasPrefix("(") { candidate.removeFirst() }
        if candidate.hasSuffix(")"), !candidate.contains("(") { candidate.removeLast() }
        guard candidate.hasPrefix("http") || candidate.lowercased().hasPrefix("geo:") else { return nil }
        return URL(string: candidate)
    }
}
