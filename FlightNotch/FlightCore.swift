import Foundation

struct Coordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    static let jerseyCity = Coordinate(latitude: 40.7178, longitude: -74.0431)

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    func distanceNM(to other: Coordinate) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1, dLon = (other.longitude - longitude) * .pi / 180
        let a = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 3440.065 * 2 * asin(sqrt(min(1, max(0, a))))
    }

    func bearing(to other: Coordinate) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let angle = atan2(sin(dLon) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon))
        return (angle * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func direction(_ bearing: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int(((bearing + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8]
    }
}

enum AircraftClass: String, CaseIterable, Identifiable, Sendable {
    case all = "All aircraft", wideBody = "Wide-body", narrowBody = "Narrow-body", other = "Other"
    var id: String { rawValue }

    static func classify(_ type: String?) -> AircraftClass {
        guard let type else { return .other }
        if ["A30", "A31", "A33", "A34", "A35", "A38", "B74", "B76", "B77", "B78", "MD11", "DC10", "IL96"].contains(where: type.hasPrefix) {
            return .wideBody
        }
        if ["A318", "A319", "A320", "A321", "A19N", "A20N", "A21N", "BCS1", "BCS3", "B712"].contains(type)
            || ["B73", "B38", "B39", "B3XM", "B75", "MD8", "MD9", "E19", "E29", "E17", "E27"].contains(where: type.hasPrefix) {
            return .narrowBody
        }
        return .other
    }
}

enum FlightPhase: String, Sendable {
    case landing = "Landing", departing = "Departing", overhead = "Overhead", ground = "On ground", unknown = "Unknown"
    var symbol: String {
        switch self {
        case .landing: "airplane.arrival"
        case .departing: "airplane.departure"
        case .overhead: "airplane"
        case .ground: "airplane.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

enum AircraftSize: String, Sendable {
    case light, small, medium, large, heavy, superHeavy, unknown

    var markerLength: Double {
        switch self {
        case .light: 16
        case .small: 20
        case .medium: 25
        case .large: 29
        case .heavy: 34
        case .superHeavy: 38
        case .unknown: 23
        }
    }

    static func classify(type: String?, category: String?) -> AircraftSize {
        // Known families distinguish regional jets from full-size airliners
        // even when both broadcast A3. Remaining sizes use the ADS-B category.
        if type == "A388" { return .superHeavy }
        if AircraftClass.classify(type) == .wideBody { return .heavy }
        if let type, ["CRJ", "E170", "E75", "E135", "E145", "AT4", "AT7", "DH8"].contains(where: type.hasPrefix) { return .small }
        switch category {
        case "A1", "A7", "B1", "B2", "B4": return .light
        case "A2": return .small
        case "A3": return .medium
        case "A4": return .large
        case "A5": return .heavy
        case "A6": return .medium
        default: break
        }
        if AircraftClass.classify(type) == .narrowBody { return .medium }
        if let type, ["C150", "C152", "C172", "C177", "C182", "C185", "C206", "C208", "PA28", "PA32", "PA34", "SR20", "SR22", "BE36", "BE58", "R22", "R44", "R66", "B06", "B407"].contains(type) { return .light }
        return .unknown
    }
}

struct Aircraft: Decodable, Identifiable, Sendable {
    let id: String
    let callsign: String?
    let registration: String?
    let typeCode: String?
    let typeDescription: String?
    let emitterCategory: String?
    let altitude: Double?
    let onGround: Bool
    let speed: Double?
    let track: Double?
    let verticalRate: Double?
    let coordinate: Coordinate?
    let positionAge: Double?

    enum CodingKeys: String, CodingKey {
        case hex, flight, r, t, desc, category, alt_baro, gs, track, baro_rate, geom_rate, lat, lon, seen_pos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .hex)
        guard !id.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .hex, in: c, debugDescription: "Missing aircraft identifier") }
        func clean(_ key: CodingKeys) -> String? {
            guard let text = try? c.decode(String.self, forKey: key) else { return nil }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return value.isEmpty ? nil : value
        }
        func number(_ key: CodingKeys) -> Double? {
            guard let value = try? c.decode(Double.self, forKey: key), value.isFinite else { return nil }
            return value
        }
        callsign = clean(.flight)
        registration = clean(.r)
        typeCode = clean(.t)
        typeDescription = clean(.desc)
        emitterCategory = clean(.category)
        onGround = clean(.alt_baro) == "GROUND"
        altitude = number(.alt_baro)
        speed = number(.gs).flatMap { $0 >= 0 ? $0 : nil }
        track = number(.track).map { ($0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
        verticalRate = number(.baro_rate) ?? number(.geom_rate)
        positionAge = number(.seen_pos)
        if let lat = number(.lat), let lon = number(.lon), Coordinate(latitude: lat, longitude: lon).isValid {
            coordinate = Coordinate(latitude: lat, longitude: lon)
        } else {
            coordinate = nil
        }
    }

    var displayName: String { callsign ?? registration ?? id.uppercased() }
    var aircraftClass: AircraftClass { AircraftClass.classify(typeCode) }
    var size: AircraftSize { AircraftSize.classify(type: typeCode, category: emitterCategory) }
    var typeName: String {
        if let description = typeDescription, description != typeCode {
            // Keep feed-supplied variants and model identifiers; soften prose casing.
            let acronyms: Set<String> = ["MAX", "ERJ", "CRJ", "ATR", "DHC", "TBM", "II", "III", "IV", "NG", "NGX", "ER", "LR", "XLR"]
            return description.split(separator: " ").map { word in
                word.contains(where: \.isNumber) || acronyms.contains(String(word)) ? String(word) : word.capitalized
            }.joined(separator: " ")
        }
        return typeCode.flatMap { Self.typeNames[$0] } ?? typeCode ?? "Unknown aircraft"
    }

    // Common ICAO designators. These identify families/variants, not exact airframes.
    // References: FAA aircraft type designators and EUROCONTROL aircraft database.
    private static let typeNames = [
        "A319": "Airbus A319", "A320": "Airbus A320", "A321": "Airbus A321",
        "A19N": "Airbus A319neo", "A20N": "Airbus A320neo", "A21N": "Airbus A321neo",
        "B737": "Boeing 737-700", "B738": "Boeing 737-800", "B739": "Boeing 737-900",
        "B38M": "Boeing 737 MAX 8", "B39M": "Boeing 737 MAX 9",
        "E170": "Embraer E170", "E75L": "Embraer E175 (long wing)", "E75S": "Embraer E175 (short wing)",
        "CRJ7": "Bombardier CRJ-700", "CRJ9": "Bombardier CRJ-900",
        "B06": "Bell 206", "B407": "Bell 407", "B429": "Bell 429",
        "S76": "Sikorsky S-76", "R44": "Robinson R44",
        "C172": "Cessna 172", "C182": "Cessna 182", "SR22": "Cirrus SR22"
    ]
    var phase: FlightPhase {
        if onGround { return .ground }
        guard let altitude, let verticalRate else { return .unknown }
        if altitude < 6000 && verticalRate < -300 { return .landing }
        if altitude < 10000 && verticalRate > 300 { return .departing }
        return .overhead
    }
}

struct FlightFeed: Decodable, Sendable {
    let aircraft: [Aircraft]
    let timestamp: Date?
    enum CodingKeys: String, CodingKey { case ac, now, msg }

    private struct Record: Decodable {
        let value: Aircraft?
        init(from decoder: Decoder) throws { value = try? Aircraft(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let message = try c.decodeIfPresent(String.self, forKey: .msg), !["No error", "No aircraft"].contains(message) {
            throw DecodingError.dataCorruptedError(forKey: .msg, in: c, debugDescription: message)
        }
        // One malformed aircraft must not discard the whole surrounding sky.
        aircraft = try c.decode([Record].self, forKey: .ac).compactMap(\.value)
        timestamp = try c.decodeIfPresent(Double.self, forKey: .now).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

struct NearbyFlight: Identifiable, Sendable {
    let aircraft: Aircraft
    let distance: Double
    let bearing: Double
    var id: String { aircraft.id }
    var direction: String { Coordinate.direction(bearing) }
}

struct FlightFilter: Sendable {
    var radius: Double = 5
    var airline: String = ""
    var aircraftClass: AircraftClass = .all

    var airlinePrefixes: [String] {
        airline.uppercased().split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    func apply(to aircraft: [Aircraft], around origin: Coordinate, elapsed: TimeInterval = 0) -> [NearbyFlight] {
        var identifiers = Set<String>()
        return aircraft.compactMap { aircraft -> NearbyFlight? in
            guard let coordinate = aircraft.coordinate, !aircraft.onGround,
                  let age = aircraft.positionAge, age >= 0, age + max(0, elapsed) <= 60,
                  aircraftClass == .all || aircraft.aircraftClass == aircraftClass,
                  airlinePrefixes.isEmpty || airlinePrefixes.contains(where: { aircraft.callsign?.hasPrefix($0) == true }) else { return nil }
            let distance = origin.distanceNM(to: coordinate)
            guard distance <= radius, identifiers.insert(aircraft.id).inserted else { return nil }
            return NearbyFlight(aircraft: aircraft, distance: distance, bearing: origin.bearing(to: coordinate))
        }.sorted { $0.distance == $1.distance ? $0.id < $1.id : $0.distance < $1.distance }
    }
}

enum FeedError: LocalizedError {
    case http(Int, retryAfter: TimeInterval?)
    case stale

    var errorDescription: String? {
        switch self {
        case .http(429, _): "Feed rate limit reached. Waiting before retrying."
        case .http(let code, _): "Feed unavailable (HTTP \(code)). Retrying automatically."
        case .stale: "The feed returned old data. Waiting for a fresh update."
        }
    }
}

enum FeedProvider: String, CaseIterable, Identifiable, Sendable {
    case adsbFi = "adsb.fi"
    case adsbLol = "adsb.lol"
    var id: String { rawValue }
    var website: URL { URL(string: "https://\(rawValue)")! }
    var backoffKey: String { "serverBackoff.\(rawValue)" }

    func url(around origin: Coordinate, radius: Double) -> URL {
        let distance = Int(radius.rounded(.up))
        switch self {
        case .adsbFi:
            return URL(string: "https://opendata.adsb.fi/api/v3/lat/\(origin.latitude)/lon/\(origin.longitude)/dist/\(distance)")!
        case .adsbLol:
            return URL(string: "https://api.adsb.lol/v2/point/\(origin.latitude)/\(origin.longitude)/\(distance)")!
        }
    }
}

struct FlightClient: Sendable {
    var session: URLSession = .shared

    func fetch(around origin: Coordinate, radius: Double, provider: FeedProvider = .adsbFi) async throws -> FlightFeed {
        let url = provider.url(around: origin, radius: radius)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("FlightNotch/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            throw FeedError.http(http.statusCode, retryAfter: Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
        }
        let feed = try JSONDecoder().decode(FlightFeed.self, from: data)
        guard let timestamp = feed.timestamp, abs(timestamp.timeIntervalSinceNow) < 60 else { throw FeedError.stale }
        return feed
    }

    static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = TimeInterval(header), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
}
