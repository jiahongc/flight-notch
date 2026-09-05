import XCTest
@testable import FlightCore

final class FlightCoreTests: XCTestCase {
    private func decode(_ fields: String = "") throws -> Aircraft {
        try JSONDecoder().decode(Aircraft.self, from: Data("{\"hex\":\"abc123\",\"lat\":40.72,\"lon\":-74.04,\"seen_pos\":1\(fields)}".utf8))
    }

    func testDistanceAndBearing() {
        let origin = Coordinate(latitude: 0, longitude: 0)
        XCTAssertEqual(origin.distanceNM(to: origin), 0)
        XCTAssertEqual(origin.distanceNM(to: Coordinate(latitude: 1, longitude: 0)), 60.04, accuracy: 0.02)
        XCTAssertEqual(origin.bearing(to: Coordinate(latitude: 0, longitude: 1)), 90, accuracy: 0.001)
        XCTAssertEqual(origin.bearing(to: Coordinate(latitude: -1, longitude: 0)), 180, accuracy: 0.001)
        XCTAssertEqual(Coordinate.direction(359), "N")
        XCTAssertEqual(Coordinate.direction(225), "SW")
        XCTAssertLessThan(Coordinate(latitude: 0, longitude: 179.9).distanceNM(to: Coordinate(latitude: 0, longitude: -179.9)), 13)
    }

    func testMixedAltitudeAndUnknownTelemetry() throws {
        let ground = try decode(",\"alt_baro\":\"ground\",\"flight\":\" UAL123  \",\"t\":\"B77W\"")
        XCTAssertEqual(ground.phase, .ground)
        XCTAssertEqual(ground.displayName, "UAL123")
        XCTAssertEqual(ground.aircraftClass, .wideBody)
        let missing = try decode(",\"flight\":\"   \",\"r\":\"N123AB\"")
        XCTAssertEqual(missing.phase, .unknown)
        XCTAssertNil(missing.altitude)
        XCTAssertEqual(missing.displayName, "N123AB")
        XCTAssertEqual(try decode().displayName, "ABC123")
    }

    func testPhaseThresholdsAndGeometricRateFallback() throws {
        XCTAssertEqual(try decode(",\"alt_baro\":5900,\"baro_rate\":-301").phase, .landing)
        XCTAssertEqual(try decode(",\"alt_baro\":6000,\"baro_rate\":-900").phase, .overhead)
        XCTAssertEqual(try decode(",\"alt_baro\":3000,\"baro_rate\":-300").phase, .overhead)
        XCTAssertEqual(try decode(",\"alt_baro\":9999,\"geom_rate\":301").phase, .departing)
        XCTAssertEqual(try decode(",\"alt_baro\":10000,\"baro_rate\":600").phase, .overhead)
        XCTAssertEqual(try decode(",\"alt_baro\":3000").phase, .unknown)
    }

    func testTypeClassification() {
        for code in ["B77W", "B789", "A359", "A388", "B763", "MD11"] { XCTAssertEqual(AircraftClass.classify(code), .wideBody, code) }
        for code in ["A321", "A20N", "B738", "B38M", "B39M", "B3XM", "E190", "BCS3"] { XCTAssertEqual(AircraftClass.classify(code), .narrowBody, code) }
        for code in ["C172", "CRJ9", "H60", "ZZZZ"] { XCTAssertEqual(AircraftClass.classify(code), .other, code) }
        XCTAssertEqual(AircraftClass.classify(nil), .other)
    }

    func testReadableAircraftType() throws {
        let plane = try decode(",\"t\":\"B39M\",\"desc\":\"BOEING 737 MAX 9\"")
        XCTAssertEqual(plane.typeName, "Boeing 737 MAX 9")
        XCTAssertEqual(try decode(",\"t\":\"A321\"").typeName, "A321")
        XCTAssertEqual(try decode().typeName, "Unknown aircraft")
    }

    func testAircraftSizeUsesTypeAndBroadcastCategory() throws {
        let light = try decode(",\"t\":\"C172\",\"category\":\"A1\"")
        let regional = try decode(",\"t\":\"CRJ9\",\"category\":\"A3\"")
        let airliner = try decode(",\"t\":\"B738\",\"category\":\"A3\"")
        let heavy = try decode(",\"t\":\"B77W\",\"category\":\"A5\"")
        XCTAssertEqual(light.emitterCategory, "A1")
        XCTAssertEqual(light.size, .light)
        XCTAssertEqual(regional.size, .small)
        XCTAssertLessThan(light.size.markerLength, regional.size.markerLength)
        XCTAssertLessThan(regional.size.markerLength, airliner.size.markerLength)
        XCTAssertLessThan(airliner.size.markerLength, heavy.size.markerLength)
        XCTAssertEqual(try decode(",\"t\":\"A388\"").size, .superHeavy)
        XCTAssertEqual(try decode(",\"category\":\"A2\"").size, .small)
        XCTAssertEqual(try decode(",\"category\":\"A7\"").size, .light)
        XCTAssertEqual(try decode(",\"t\":\"C172\"").size, .light)
        XCTAssertEqual(try decode(",\"t\":\"C17\",\"category\":\"A5\"").size, .heavy)
        XCTAssertEqual(try decode().size, .unknown)
    }

    func testRoutePlausibilityRejectsObservedStaleCallsignAssignment() throws {
        let westCoast = try JSONDecoder().decode(FlightRoute.self, from: Data(RouteStub.routeJSON(callsign: "UAL388", westCoast: true).utf8))
        XCTAssertFalse(westCoast.isPlausible(near: .jerseyCity), "LAX–SEA cannot explain UAL388 near NYC")
        XCTAssertTrue(westCoast.isPlausible(near: westCoast.origin!.coordinate))
        XCTAssertEqual(westCoast.origin?.code, "LAX")
        let newark = try JSONDecoder().decode(FlightRoute.self, from: Data(RouteStub.routeJSON(callsign: "DAL1").utf8))
        XCTAssertTrue(newark.isPlausible(near: .jerseyCity))
        XCTAssertTrue(newark.matches("DAL1"))
        XCTAssertFalse(newark.matches("UAL1"))
    }

    func testRouteLookupMissingAndMatchedResponses() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteStub.self]
        let client = RouteClient(session: URLSession(configuration: config))
        let route = try await client.lookup("DAL1", near: .jerseyCity)
        XCTAssertEqual(route?.origin?.code, "EWR")
        XCTAssertEqual(route?.destination?.code, "SEA")
        let cached = try await client.lookup("DAL1", near: .jerseyCity)
        XCTAssertEqual(cached?.callsign, "DAL1")
        let missing = try await client.lookup("ZZZ999", near: .jerseyCity)
        XCTAssertNil(missing)
        let registration = try await client.lookup("N123AB", near: .jerseyCity)
        XCTAssertNil(registration)
        let mismatch = try await client.lookup("UAL2", near: .jerseyCity)
        XCTAssertNil(mismatch)
    }

    func testRouteRejectionAndIntermediateStop() throws {
        let json = RouteStub.routeJSON(callsign: "UAL1", westCoast: true)
        let rejected = try JSONDecoder().decode(FlightRoute.self, from: Data(json.replacingOccurrences(of: "\"plausible\":true", with: "\"plausible\":false").utf8))
        XCTAssertFalse(rejected.isPlausible(near: rejected.origin!.coordinate), "Honor the provider's explicit rejection even near an airport")
        var multi = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var airports = try XCTUnwrap(multi["_airports"] as? [[String: Any]])
        airports.insert(["iata": "EWR", "icao": "KEWR", "name": "Newark", "lat": 40.6925, "lon": -74.1687], at: 1)
        multi["_airports"] = airports
        let route = try JSONDecoder().decode(FlightRoute.self, from: JSONSerialization.data(withJSONObject: multi))
        XCTAssertTrue(route.isPlausible(near: .jerseyCity), "LAX–EWR–SEA must check its individual legs")
        XCTAssertEqual(route.via, "EWR")
        let unknown = try JSONDecoder().decode(FlightRoute.self, from: Data(#"{"callsign":"UAL1","_airports":null}"#.utf8))
        XCTAssertFalse(unknown.isPlausible(near: .jerseyCity))
    }

    func testObservedAAL2723RouteUsesLaGuardia() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteStub.self]
        let client = RouteClient(session: URLSession(configuration: config))
        let route = try await client.lookup("AAL2723", near: Coordinate(latitude: 40.777887, longitude: -73.875207))
        XCTAssertEqual(route?.origin?.code, "ORD")
        XCTAssertEqual(route?.destination?.code, "LGA", "Use the new position-aware response, not the former ORD–PHL database assignment")
        XCTAssertEqual(route?.destination?.municipality, "New York")
    }

    func testPaddedCallsignUsesCanonicalRouteAndCache() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteStub.self]
        let client = RouteClient(session: URLSession(configuration: config))
        // The live service returned unknown for UAL02759 but ORD-EWR for UAL2759.
        let padded = try await client.lookup("UAL02759", near: .jerseyCity)
        XCTAssertEqual(padded?.callsign, "UAL2759")
        let canonical = try await client.lookup("UAL2759", near: .jerseyCity)
        XCTAssertEqual(canonical?.origin?.code, padded?.origin?.code)
        XCTAssertTrue(padded?.matches(" ual02759 ") == true)
        XCTAssertFalse(padded?.matches("UAL2758") == true)
        XCTAssertEqual(RouteClient.normalizedCallsign("BAW001A"), "BAW1A")
        XCTAssertEqual(RouteClient.normalizedCallsign("N001AB"), "N001AB", "Do not rewrite aircraft registrations")
        XCTAssertEqual(RouteClient.normalizedCallsign("BAW0A"), "BAW0A", "Keep a single zero")
    }

    @MainActor
    func testMissingFlightNumberAndRouteAreDifferentStates() async throws {
        let suite = "RouteMessages-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "useLocation")
        preferences.set(2.0, forKey: "radius")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MissingRouteStub.self]
        let store = FlightStore(preferences: preferences, client: client(), routeClient: RouteClient(session: URLSession(configuration: config)))
        XCTAssertEqual(store.selectedRouteMessage, "No flight number")
        store.start()
        defer { store.stop() }
        for _ in 0..<100 where store.lastUpdate == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.selectedFlight?.aircraft.callsign, "DAL1")
        await store.loadSelectedRoute()
        XCTAssertNil(store.selectedRoute)
        XCTAssertEqual(store.selectedRouteMessage, "No route published")
        store.stop()
        preferences.set(6.0, forKey: "radius")
        let privateFlight = FlightStore(preferences: preferences, client: client())
        privateFlight.start()
        defer { privateFlight.stop() }
        for _ in 0..<100 where privateFlight.lastUpdate == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(privateFlight.selectedFlight?.aircraft.registration, "N123AB")
        await privateFlight.loadSelectedRoute()
        XCTAssertNil(privateFlight.selectedRoute)
        XCTAssertEqual(privateFlight.selectedRouteMessage, "No flight number")
    }

    func testRouteCooldownStopsFurtherNetworkRequests() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouteStub.self]
        let client = RouteClient(session: URLSession(configuration: config))
        for callsign in ["ERR429", "DAL1"] {
            do {
                _ = try await client.lookup(callsign, near: .jerseyCity)
                XCTFail("Rate limited route lookup should throw")
            } catch FeedError.http(let status, let retryAfter) {
                XCTAssertEqual(status, 429)
                XCTAssertGreaterThan(retryAfter ?? 0, 175)
            }
        }
    }

    func testFilteringDeduplicationAndPositionExpiry() throws {
        let plane = try decode(",\"flight\":\"DAL2365\",\"t\":\"A321\"")
        let filter = FlightFilter(radius: 5, airline: "ual, dal", aircraftClass: .narrowBody)
        XCTAssertEqual(filter.apply(to: [plane, plane], around: .jerseyCity).count, 1)
        XCTAssertEqual(filter.apply(to: [plane], around: .jerseyCity, elapsed: 59).count, 1)
        XCTAssertTrue(filter.apply(to: [plane], around: .jerseyCity, elapsed: 60).isEmpty)
        XCTAssertTrue(FlightFilter(airline: "AAL").apply(to: [plane], around: .jerseyCity).isEmpty)
        XCTAssertTrue(FlightFilter(aircraftClass: .wideBody).apply(to: [plane], around: .jerseyCity).isEmpty)
        XCTAssertTrue(filter.apply(to: [plane], around: Coordinate(latitude: 0, longitude: 0)).isEmpty)
        let ground = try decode(",\"alt_baro\":\"ground\"")
        XCTAssertTrue(FlightFilter().apply(to: [ground], around: .jerseyCity).isEmpty)
    }

    func testInvalidCoordinatesAndMissingAgeAreExcluded() throws {
        let data = Data("{\"ac\":[{\"hex\":\"a\",\"lat\":91,\"lon\":0,\"seen_pos\":0},{\"hex\":\"b\",\"lat\":40.72,\"lon\":-74.04}]}".utf8)
        let feed = try JSONDecoder().decode(FlightFeed.self, from: data)
        XCTAssertNil(feed.aircraft[0].coordinate)
        XCTAssertTrue(FlightFilter().apply(to: feed.aircraft, around: .jerseyCity).isEmpty)
    }

    func testMalformedRecordDoesNotDiscardValidFeed() throws {
        let data = Data("{\"ac\":[{\"hex\":\"abc\",\"flight\":\" DAL1 \"},{\"flight\":\"BAD\"},null],\"now\":1788612648000,\"msg\":\"No error\"}".utf8)
        let feed = try JSONDecoder().decode(FlightFeed.self, from: data)
        XCTAssertEqual(feed.aircraft.count, 1)
        XCTAssertEqual(feed.timestamp?.timeIntervalSince1970, 1788612648)
        XCTAssertThrowsError(try JSONDecoder().decode(FlightFeed.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(FlightFeed.self, from: Data("{\"ac\":[],\"msg\":\"Server error\"}".utf8)))
    }

    func testRetryAfterSecondsAndHTTPDate() {
        XCTAssertEqual(FlightClient.retryDelay("120"), 120)
        XCTAssertEqual(FlightClient.retryDelay("-3"), 0)
        XCTAssertNil(FlightClient.retryDelay("not a date"))
        XCTAssertEqual(FlightClient.retryDelay("Thu, 01 Jan 1970 00:02:00 GMT", now: Date(timeIntervalSince1970: 0)), 120)
    }

    private func client() -> FlightClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedStub.self]
        return FlightClient(session: URLSession(configuration: configuration))
    }

    func testNetworkSuccessAndStaleResponse() async throws {
        let client = client()
        let feed = try await client.fetch(around: .jerseyCity, radius: 2)
        XCTAssertEqual(feed.aircraft.count, 1)
        do {
            _ = try await client.fetch(around: .jerseyCity, radius: 4)
            XCTFail("Old feed accepted")
        } catch FeedError.stale { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRateLimitRetainsRetryAfter() async {
        do {
            _ = try await client().fetch(around: .jerseyCity, radius: 3)
            XCTFail("Rate limit accepted")
        } catch FeedError.http(let code, let retryAfter) {
            XCTAssertEqual(code, 429)
            XCTAssertEqual(retryAfter, 120)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testBackoffSurvivesPauseAndRelaunch() async throws {
        let suite = "FlightNotchTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "useLocation")
        preferences.set(3.0, forKey: "radius")
        let store = FlightStore(preferences: preferences, client: client())
        store.start()
        defer { store.stop() }
        for _ in 0..<100 where store.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }
        let deadline = try XCTUnwrap(store.nextAttempt)
        XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 118)
        XCTAssertEqual(preferences.object(forKey: FeedProvider.adsbFi.backoffKey) as? Date, deadline)
        store.setPaused(true)
        XCTAssertEqual(store.retryLabel, "Tracking paused")
        let relaunched = FlightStore(preferences: preferences, client: client())
        relaunched.start()
        defer { relaunched.stop() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(relaunched.lastUpdate)
        XCTAssertFalse(relaunched.isLoading)
        XCTAssertEqual(relaunched.nextAttempt, deadline)
        XCTAssertTrue(relaunched.retryLabel.hasPrefix("Retry in"))
        relaunched.provider = .adsbLol
        relaunched.provider = .adsbFi
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(relaunched.nextAttempt, deadline, "Switching providers must preserve each provider’s cooldown")
    }

    func testProviderEndpoints() {
        XCTAssertEqual(FeedProvider.adsbFi.url(around: .jerseyCity, radius: 5).absoluteString,
                       "https://opendata.adsb.fi/api/v3/lat/40.7178/lon/-74.0431/dist/5")
        XCTAssertEqual(FeedProvider.adsbLol.url(around: .jerseyCity, radius: 5).absoluteString,
                       "https://api.adsb.lol/v2/point/40.7178/-74.0431/5")
    }

    @MainActor
    func testStoreFallbackPersistenceAndPause() async throws {
        let suite = "FlightNotchTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "useLocation")
        preferences.set(2.0, forKey: "radius")
        let routeConfig = URLSessionConfiguration.ephemeral
        routeConfig.protocolClasses = [RouteStub.self]
        let store = FlightStore(preferences: preferences, client: client(), routeClient: RouteClient(session: URLSession(configuration: routeConfig)))
        store.start()
        defer { store.stop() }
        for _ in 0..<100 where store.lastUpdate == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.lastUpdate)
        XCTAssertEqual(store.coordinate, .jerseyCity)
        XCTAssertTrue(store.locationLabel.contains("fallback"))
        XCTAssertEqual(store.flights.count, 1)
        await store.loadSelectedRoute()
        XCTAssertEqual(store.selectedRoute?.origin?.code, "EWR")
        store.airline = "AAL"
        XCTAssertTrue(store.flights.isEmpty)
        XCTAssertNil(store.selectedRoute)
        XCTAssertEqual(preferences.string(forKey: "airline"), "AAL")
        store.setPaused(true)
        XCTAssertEqual(store.statusLabel, "Paused")
        XCTAssertFalse(store.isFresh)
        store.resetFilters()
        XCTAssertEqual(store.flights.count, 1)
    }
}

private final class FeedStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let radius = request.url!.lastPathComponent
        let status = radius == "3" ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "120"])!
        let timestamp = radius == "4" ? 0 : Date().timeIntervalSince1970 * 1000
        let identity = radius == "6" ? #""flight":"N123AB","r":"N123AB""# : #""flight":"DAL1""#
        let data = Data("{\"ac\":[{\"hex\":\"test\",\(identity),\"lat\":40.72,\"lon\":-74.04,\"seen_pos\":0}],\"now\":\(timestamp)}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class MissingRouteStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class RouteStub: URLProtocol, @unchecked Sendable {
    static func routeJSON(callsign: String, westCoast: Bool = false) -> String {
        """
        {"callsign":"\(callsign)","plausible":true,
        "_airports":[{"iata":"\(westCoast ? "LAX" : "EWR")","icao":"\(westCoast ? "KLAX" : "KEWR")","name":"Origin Airport","location":"Origin City","lat":\(westCoast ? 33.94 : 40.69),"lon":\(westCoast ? -118.4 : -74.17)},
        {"iata":"SEA","icao":"KSEA","name":"Seattle Tacoma International Airport","location":"Seattle","lat":47.45,"lon":-122.31}]}
        """
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if let data = request.httpBody { body = data }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = Data() }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let plane = (json?["planes"] as? [[String: Any]])?.first
        let callsign = (plane?["callsign"] as? String) ?? "INVALID"
        let validRequest = request.url?.absoluteString == "https://adsb.im/api/0/routeset" && request.httpMethod == "POST"
            && plane?["lat"] is Double && plane?["lng"] is Double
        let status = !validRequest ? 400 : callsign == "ERR429" ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "180"])!
        var route = Self.routeJSON(callsign: callsign == "UAL2" ? "WRONG" : callsign)
        if callsign == "AAL2723" {
            // Observed ADSB.im payload for the aircraft at LaGuardia on 2026-09-05.
            route = #"{"callsign":"AAL2723","plausible":true,"_airports":[{"iata":"ORD","icao":"KORD","name":"Chicago O'Hare International Airport","location":"Chicago","lat":41.9786,"lon":-87.9048},{"iata":"LGA","icao":"KLGA","name":"La Guardia Airport","location":"New York","lat":40.777199,"lon":-73.872597}]}"#
        }
        let data = Data((callsign == "ZZZ999" ? "[]" : "[\(route)]").utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
