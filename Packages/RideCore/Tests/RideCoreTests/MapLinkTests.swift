import Foundation
import Testing
@testable import RideCore

@Suite("Map link parser")
struct MapLinkTests {
    func place(_ text: String) -> (Double, Double, String?)? {
        guard case .place(let c, let name) = MapLinkParser.parse(text) else { return nil }
        return (c.latitude, c.longitude, name)
    }

    @Test func appleMapsLinks() throws {
        let a = try #require(place("https://maps.apple.com/?ll=12.973240,77.591600&q=Cubbon%20Park"))
        #expect(a.0 == 12.97324 && a.1 == 77.5916 && a.2 == "Cubbon Park")
        let b = try #require(place("http://maps.apple.com/?daddr=13.01097,77.55526"))
        #expect(b.0 == 13.01097 && b.2 == nil)
        let c = try #require(place("Orion Mall\nhttps://maps.apple.com/place?coordinate=13.010970,77.555260&name=Orion"))
        #expect(c.0 == 13.01097)
    }

    @Test func googleMapsLinks() throws {
        let a = try #require(place("https://www.google.com/maps/place/Lalbagh+Botanical+Garden/@12.9507,77.5848,17z/data=!4m6!3m5!1s0x0:0x0!8m2!3d12.9498!4d77.5866"))
        #expect(a.0 == 12.9498 && a.1 == 77.5866, "the place pin wins over the camera position")
        #expect(a.2 == "Lalbagh Botanical Garden")
        let b = try #require(place("https://maps.google.com/?q=12.9716,77.5946"))
        #expect(b.0 == 12.9716 && b.1 == 77.5946)
        let c = try #require(place("https://www.google.com/maps/dir/?api=1&destination=12.9352,77.6245"))
        #expect(c.0 == 12.9352)
        let d = try #require(place("https://www.google.com/maps/@12.9716,77.5946,15z"))
        #expect(d.1 == 77.5946)
    }

    @Test func whatsAppLocationMessage() throws {
        let p = try #require(place("📍 Location: https://maps.google.com/maps?q=12.935200%2C77.624500&z=17&hl=en"))
        #expect(p.0 == 12.9352 && p.1 == 77.6245)
    }

    @Test func geoUris() throws {
        let a = try #require(place("geo:12.97,77.59"))
        #expect(a.0 == 12.97)
        let b = try #require(place("geo:0,0?q=12.95,77.58(Office)"))
        #expect(b.0 == 12.95 && b.2 == "Office")
        #expect(place("geo:0,0") == nil)
    }

    @Test func plainTextAndPlusCodes() throws {
        #expect(place("12.9716, 77.5946")?.0 == 12.9716)
        #expect(place("Meet at 12.97160, 77.59460 near the gate")?.1 == 77.5946)
        #expect(try #require(place("Pin: 7J4VWHC2+VG see you")).0 > 12)
    }

    @Test func directionsNeverImportTheOriginOrTheMapCentre() throws {
        #expect(place("https://www.google.com/maps/dir/?api=1&origin=12.9700,77.5900&destination=Airport") == nil,
                "an unresolvable destination is rejected, not replaced by the origin")
        #expect(place("Leaving now https://www.google.com/maps/dir/?api=1&origin=12.9700,77.5900&destination=Airport") == nil)
        let both = try #require(place("https://www.google.com/maps/dir/?api=1&origin=12.9700,77.5900&destination=13.0100,77.5500"))
        #expect(both.0 == 13.01 && both.1 == 77.55)
        #expect(place("https://www.google.com/maps/dir/12.9700,77.5900/Airport/@12.99,77.60,12z") == nil)
        let path = try #require(place("https://www.google.com/maps/dir/12.9700,77.5900/13.0100,77.5500/@12.99,77.57,12z"))
        #expect(path.0 == 13.01 && path.1 == 77.55, "the last stop of a directions path is the destination")
        #expect(place("https://www.google.com/maps/dir/12.9700,77.5900/@12.97,77.59,12z") == nil, "a lone stop is an origin")
        #expect(place("https://www.google.com/maps/search/petrol/@12.9716,77.5946,15z") == nil)

        let apple = try #require(place("https://maps.apple.com/?ll=12.9700,77.5900&daddr=13.0100,77.5500"))
        #expect(apple.0 == 13.01 && apple.1 == 77.55, "daddr is the destination; ll is the map centre")
        #expect(place("https://maps.apple.com/?ll=12.9700,77.5900&daddr=Kempegowda%20Airport") == nil)
        #expect(place("https://maps.apple.com/?q=Coffee&sll=12.9700,77.5900") == nil, "a search centre is not a place")
    }

    @Test func mistypedCoordinatesAreRejectedNotTruncated() {
        #expect(place("Meet at 112.9716, 77.5946") == nil)
        #expect(place("Meet at 12.9716, 1177.5946") == nil)
        #expect(place("ref 3.12.9716, 77.5946") == nil)
        #expect(place("Meet at -12.9716, 77.5946")?.0 == -12.9716)
        #expect(place("Dinner at 12.97160, 77.59460 https://example.com/menu?id=12.3456,77.1234")?.0 == 12.9716,
                "text beside an unrelated link is still read; the link itself is not")
    }

    @Test func shortLinksNeedExpansion() {
        #expect(MapLinkParser.parse("https://maps.app.goo.gl/AbCdEf123") == .needsExpansion(URL(string: "https://maps.app.goo.gl/AbCdEf123")!))
        #expect(MapLinkParser.parse("check https://goo.gl/maps/xyz") == .needsExpansion(URL(string: "https://goo.gl/maps/xyz")!))
    }

    @Test func rejectsNonLocations() {
        #expect(MapLinkParser.parse("") == nil)
        #expect(MapLinkParser.parse("hello there") == nil)
        #expect(MapLinkParser.parse("https://example.com/page?id=12") == nil)
        #expect(MapLinkParser.parse("https://maps.google.com/?q=95.0,77.0") == nil)
    }
}

@Suite("Map link hosts")
struct MapLinkHostTests {
    @Test func onlyGenuineMapHostsAreTrusted() {
        for host in ["google.com", "www.google.com", "maps.google.co.in", "www.google.com.au", "google.de"] {
            #expect(MapLinkParser.isGoogleHost(host), "\(host)")
        }
        for host in ["google.evil.com", "notgoogle.com", "google.com.evil.io", "evil-google.com", "google"] {
            #expect(!MapLinkParser.isGoogleHost(host), "\(host)")
        }
        #expect(MapLinkParser.isAppleMapsHost("maps.apple.com") && !MapLinkParser.isAppleMapsHost("maps.apple.com.evil.io"))
        #expect(MapLinkParser.parse("https://google.evil.com/maps/place/x/data=!3d12.9498!4d77.5866") == nil)
        #expect(MapLinkParser.parse("https://www.google.com/maps/place/x/data=!3d12.9498!4d77.5866") != nil)
    }
}
