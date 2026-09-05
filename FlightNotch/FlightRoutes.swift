import Foundation

struct RouteAirport: Decodable, Sendable {
    let iata: String?
    let icao: String
    let name: String
    let municipality: String?
    let latitude: Double
    let longitude: Double
    enum CodingKeys: String, CodingKey {
        case iata, icao, name, municipality = "location", latitude = "lat", longitude = "lon"
    }
    var code: String { iata.flatMap { $0.isEmpty ? nil : $0 } ?? icao }
    var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

struct FlightRoute: Decodable, Sendable {
    let callsign: String
    let airports: [RouteAirport]
    let plausible: Bool?
    enum CodingKeys: String, CodingKey { case callsign, airports = "_airports", plausible }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callsign = try c.decode(String.self, forKey: .callsign)
        airports = try c.decodeIfPresent([RouteAirport].self, forKey: .airports) ?? []
        plausible = try c.decodeIfPresent(Bool.self, forKey: .plausible)
    }

    var origin: RouteAirport? { airports.first }
    var destination: RouteAirport? { airports.last }
    var via: String? {
        airports.count > 2 ? airports.dropFirst().dropLast().map(\.code).joined(separator: " · ") : nil
    }

    func matches(_ requestedCallsign: String) -> Bool {
        callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == requestedCallsign
    }

    func isPlausible(near point: Coordinate) -> Bool {
        guard plausible != false, point.isValid, airports.count >= 2,
              airports.allSatisfy({ $0.coordinate.isValid && !$0.icao.isEmpty }) else { return false }
        // Check each leg, so a valid itinerary with an intermediate stop isn't
        // rejected against a great-circle route that skips that stop.
        return zip(airports, airports.dropFirst()).contains { origin, destination in
            let direct = origin.coordinate.distanceNM(to: destination.coordinate)
            let viaAircraft = origin.coordinate.distanceNM(to: point) + point.distanceNM(to: destination.coordinate)
            return viaAircraft - direct <= max(100, direct * 0.15)
        }
    }
}

actor RouteClient {
    private struct RequestBody: Encodable {
        struct Plane: Encodable { let callsign: String; let lat: Double; let lng: Double }
        let planes: [Plane]
    }
    private struct Record: Decodable {
        let route: FlightRoute?
        init(from decoder: Decoder) throws { route = try? FlightRoute(from: decoder) }
    }
    private struct CachedRoute {
        let route: FlightRoute?
        let expires: Date
        let position: Coordinate
    }
    private let session: URLSession
    private var cache: [String: CachedRoute] = [:]
    private var nextRequest = Date.distantPast
    private var blockedUntil = Date.distantPast

    init(session: URLSession = .shared) { self.session = session }

    func lookup(_ callsign: String, near position: Coordinate) async throws -> FlightRoute? {
        guard position.isValid,
              callsign.range(of: "^[A-Z]{3}[A-Z0-9]{1,5}$", options: .regularExpression) != nil,
              callsign.contains(where: \.isNumber) else { return nil }
        if let cached = cache[callsign], cached.expires > Date(),
           cached.position.distanceNM(to: position) < 25,
           cached.route == nil || cached.route?.isPlausible(near: position) == true { return cached.route }
        guard blockedUntil <= Date() else { throw FeedError.http(429, retryAfter: blockedUntil.timeIntervalSinceNow) }
        // Selected aircraft only. Space uncached requests to avoid loading the
        // community service while the user clicks around the map.
        while nextRequest > Date() {
            try await Task.sleep(for: .seconds(nextRequest.timeIntervalSinceNow))
        }
        try Task.checkCancellation()
        guard blockedUntil <= Date() else { throw FeedError.http(429, retryAfter: blockedUntil.timeIntervalSinceNow) }
        nextRequest = Date().addingTimeInterval(4)
        let url = URL(string: "https://adsb.im/api/0/routeset")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("FlightNotch/1.0 (personal local tracker)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(RequestBody(planes: [.init(callsign: callsign, lat: position.latitude, lng: position.longitude)]))
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else {
            let delay = FlightClient.retryDelay(response.value(forHTTPHeaderField: "Retry-After")) ?? 60
            blockedUntil = Date().addingTimeInterval(max(60, delay))
            throw FeedError.http(response.statusCode, retryAfter: delay)
        }
        let routes = try JSONDecoder().decode([Record].self, from: data).compactMap(\.route)
        let matched = routes.first { $0.matches(callsign) && $0.isPlausible(near: position) }
        remember(matched, for: callsign, near: position)
        return matched
    }

    private func remember(_ route: FlightRoute?, for callsign: String, near position: Coordinate) {
        cache = cache.filter { $0.value.expires > Date() }
        if cache.count >= 64, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key { cache.removeValue(forKey: oldest) }
        cache[callsign] = CachedRoute(route: route, expires: Date().addingTimeInterval(route == nil ? 60 : 300), position: position)
    }
}
