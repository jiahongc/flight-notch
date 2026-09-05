import Combine
import CoreLocation
import Foundation

@MainActor
final class FlightStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var radius: Double { didSet { preferences.set(radius, forKey: "radius") } }
    @Published var airline: String { didSet { preferences.set(airline, forKey: "airline") } }
    @Published var aircraftClass: AircraftClass { didSet { preferences.set(aircraftClass.rawValue, forKey: "aircraftClass") } }
    @Published var satellite: Bool { didSet { preferences.set(satellite, forKey: "satellite") } }
    @Published var provider: FeedProvider {
        didSet {
            guard provider != oldValue else { return }
            preferences.set(provider.rawValue, forKey: "provider")
            pollingTask?.cancel()
            pollingTask = nil
            aircraft = []
            lastUpdate = nil
            failureCount = 0
            restrictedFailures = 0
            retryNotBefore = preferences.object(forKey: provider.backoffKey) as? Date ?? .distantPast
            errorMessage = retryNotBefore > Date() ? "Feed cooling down. Waiting before retrying." : nil
            nextAttempt = nil
            isLoading = false
            startPolling()
        }
    }
    @Published var useLocation: Bool {
        didSet {
            preferences.set(useLocation, forKey: "useLocation")
            updateLocationAuthorization()
        }
    }
    @Published private(set) var coordinate = Coordinate.jerseyCity
    @Published private(set) var locationLabel = "Jersey City · fallback"
    @Published private(set) var locationDetail = "Using 40.7178, −74.0431 until your location is available."
    @Published private(set) var locationHasFix = false
    @Published private(set) var aircraft: [Aircraft] = []
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var paused = false
    @Published private(set) var now = Date()
    @Published private(set) var nextAttempt: Date?
    @Published var selectedID: String?
    @Published private(set) var route: FlightRoute?
    @Published private(set) var routeCallsign: String?
    @Published private(set) var routeLoading = false
    @Published private(set) var routeMessage = "No route published"

    private let preferences: UserDefaults
    private let location = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var geocodingTask: Task<Void, Never>?
    private var geocodedCoordinate: Coordinate?
    private let client: FlightClient
    private let routeClient: RouteClient
    private var pollingTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var failureCount = 0
    private var restrictedFailures = 0
    private var retryNotBefore = Date.distantPast
    private var sleeping = false

    init(preferences: UserDefaults = .standard, client: FlightClient = FlightClient(), routeClient: RouteClient = RouteClient()) {
        self.preferences = preferences
        self.client = client
        self.routeClient = routeClient
        let storedRadius = preferences.object(forKey: "radius") as? Double ?? 5
        radius = storedRadius.isFinite ? min(25, max(2, storedRadius)) : 5
        airline = preferences.string(forKey: "airline") ?? ""
        aircraftClass = AircraftClass(rawValue: preferences.string(forKey: "aircraftClass") ?? "") ?? .all
        satellite = preferences.object(forKey: "satellite") as? Bool ?? false
        provider = FeedProvider(rawValue: preferences.string(forKey: "provider") ?? "") ?? .adsbFi
        useLocation = preferences.object(forKey: "useLocation") as? Bool ?? true
        super.init()
        retryNotBefore = preferences.object(forKey: provider.backoffKey) as? Date ?? .distantPast
        if retryNotBefore > Date() { errorMessage = "Feed cooling down. Waiting before retrying." }
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        location.distanceFilter = 500
    }

    var flights: [NearbyFlight] {
        FlightFilter(radius: radius, airline: airline, aircraftClass: aircraftClass).apply(
            to: aircraft, around: coordinate, elapsed: lastUpdate.map { now.timeIntervalSince($0) } ?? 0
        )
    }

    var selectedFlight: NearbyFlight? { flights.first(where: { $0.id == selectedID }) ?? flights.first }
    var selectedRoute: FlightRoute? {
        guard let flight = selectedFlight, flight.aircraft.callsign == routeCallsign,
              let point = flight.aircraft.coordinate, let route, route.isPlausible(near: point) else { return nil }
        return route
    }
    var selectedRouteMessage: String {
        guard let aircraft = selectedFlight?.aircraft, let callsign = aircraft.callsign,
              callsign != aircraft.registration else { return "No flight number" }
        if callsign != routeCallsign || routeLoading { return "Looking up route…" }
        return route != nil && selectedRoute == nil ? "Route doesn't match position" : routeMessage
    }
    var selectedRouteDetail: String {
        if selectedRouteMessage == "No flight number" {
            return "This aircraft is broadcasting only its registration or no flight number. The free route service cannot identify its departure and destination from that alone."
        }
        if selectedRouteMessage == "No route published" {
            return "The free route service has no usable route for this callsign. Coverage varies, especially for private flights and helicopters."
        }
        return "Only routes matching this aircraft's callsign and position are shown. Lookups retry once a minute while the map is open; service cooldowns are respected."
    }

    func loadSelectedRoute() async {
        let aircraft = selectedFlight?.aircraft
        let callsign = aircraft?.callsign
        if routeCallsign != callsign { route = nil }
        routeCallsign = callsign
        routeMessage = "No route published"
        guard let callsign, callsign != aircraft?.registration, let position = aircraft?.coordinate else {
            route = nil
            routeLoading = false
            return
        }
        routeLoading = true
        do {
            let result = try await routeClient.lookup(callsign, near: position)
            try Task.checkCancellation()
            guard selectedFlight?.aircraft.callsign == callsign else { return }
            route = result
            routeLoading = false
        } catch {
            guard !Task.isCancelled, selectedFlight?.aircraft.callsign == callsign else { return }
            route = nil
            routeLoading = false
            if case FeedError.http(let status, _) = error {
                routeMessage = status == 429 || status == 403 ? "Route service cooling down" : "Route service unavailable"
            } else {
                routeMessage = "Route connection unavailable"
            }
        }
    }
    var hasFilters: Bool { !airline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aircraftClass != .all }
    var isFresh: Bool { !paused && errorMessage == nil && lastUpdate.map { now.timeIntervalSince($0) < 20 } == true }
    var statusLabel: String {
        if paused { return "Paused" }
        if errorMessage != nil { return "Reconnecting" }
        if lastUpdate == nil { return "Connecting" }
        return isFresh ? "Live" : "Updating"
    }
    var ageLabel: String {
        guard let lastUpdate else { return "Waiting for first update" }
        return "Updated \(max(0, Int(now.timeIntervalSince(lastUpdate))))s ago"
    }
    var retryLabel: String {
        if paused { return "Tracking paused" }
        guard errorMessage != nil, let nextAttempt else { return "NORTH UP  ↗" }
        return "Retry in \(max(0, Int(ceil(nextAttempt.timeIntervalSince(now)))))s"
    }

    func start() {
        updateLocationAuthorization()
        if clockTask == nil {
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.now = Date()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
        startPolling()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        clockTask?.cancel()
        clockTask = nil
        location.stopUpdatingLocation()
        geocodingTask?.cancel()
        geocoder.cancelGeocode()
    }

    func setPaused(_ value: Bool) {
        paused = value
        pollingTask?.cancel()
        pollingTask = nil
        isLoading = false
        nextAttempt = nil
        if !value { startPolling() }
    }

    func setSleeping(_ value: Bool) {
        sleeping = value
        pollingTask?.cancel()
        pollingTask = nil
        isLoading = false
        if value { location.stopUpdatingLocation() }
        else { now = Date(); updateLocationAuthorization(); startPolling() }
    }

    func resetFilters() { airline = ""; aircraftClass = .all }

    private func startPolling() {
        guard pollingTask == nil, !paused, !sleeping else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.retryNotBefore.timeIntervalSinceNow
                if wait > 0 {
                    self.nextAttempt = self.retryNotBefore
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
                let requestedOrigin = self.coordinate
                let requestedRadius = self.radius
                let requestedProvider = self.provider
                self.isLoading = true
                do {
                    let feed = try await self.client.fetch(around: requestedOrigin, radius: requestedRadius, provider: requestedProvider)
                    try Task.checkCancellation()
                    if requestedOrigin == self.coordinate && requestedRadius == self.radius && requestedProvider == self.provider {
                        self.aircraft = feed.aircraft
                        self.lastUpdate = feed.timestamp
                        self.errorMessage = nil
                        self.now = Date()
                    }
                    self.failureCount = 0
                    self.restrictedFailures = 0
                    self.preferences.removeObject(forKey: requestedProvider.backoffKey)
                    self.retryNotBefore = Date().addingTimeInterval(8)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.failureCount += 1
                    let delay = min(120, 8 * pow(2, Double(min(self.failureCount, 4))))
                    var retryDelay = delay
                    if case FeedError.http(let status, let retryAfter) = error {
                        retryDelay = max(delay, retryAfter ?? (status == 429 || status == 403 ? 60 : 0))
                        if status == 429 || status == 403 { self.restrictedFailures += 1 }
                    }
                    self.retryNotBefore = Date().addingTimeInterval(retryDelay)
                    self.preferences.set(self.retryNotBefore, forKey: requestedProvider.backoffKey)
                    self.errorMessage = (error as? FeedError)?.localizedDescription
                        ?? "Couldn’t update flights. Check your connection; we’ll retry automatically."
                    if self.restrictedFailures >= 3 {
                        self.errorMessage = "The feed repeatedly limited requests. Tracking is paused. Resume later to try again."
                        self.setPaused(true)
                        return
                    }
                }
                self.isLoading = false
                self.nextAttempt = self.retryNotBefore
            }
        }
    }

    private func useFallback(_ detail: String) {
        geocodingTask?.cancel()
        geocoder.cancelGeocode()
        geocodedCoordinate = nil
        locationHasFix = false
        if coordinate != .jerseyCity { aircraft = []; lastUpdate = nil }
        coordinate = .jerseyCity
        locationLabel = "Jersey City · fallback"
        locationDetail = detail
    }

    func refreshLocation() {
        location.stopUpdatingLocation()
        updateLocationAuthorization()
    }

    private func updateLocationAuthorization() {
        guard useLocation, !sleeping else {
            location.stopUpdatingLocation()
            if !sleeping { useFallback("Automatic location is off. Using Jersey City / NYC (40.7178, −74.0431).") }
            return
        }
        switch location.authorizationStatus {
        case .notDetermined:
            useFallback("Allow Flight Notch to use your location when macOS asks. Jersey City is used until permission is granted.")
            location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if !locationHasFix { locationDetail = "Permission granted. Finding your location…" }
            location.startUpdatingLocation()
        case .denied, .restricted:
            location.stopUpdatingLocation()
            useFallback("Location access is unavailable. Enable Flight Notch in System Settings → Privacy & Security → Location Services, or keep using Jersey City.")
        @unknown default:
            useFallback("Location is unavailable. Using Jersey City / NYC.")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.updateLocationAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 5000,
              abs(fix.timestamp.timeIntervalSinceNow) < 120 else { return }
        let coordinate = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        guard coordinate.isValid else { return }
        Task { @MainActor [weak self] in
            guard let self, self.useLocation, !self.sleeping,
                  self.location.authorizationStatus == .authorizedAlways else { return }
            if self.coordinate.distanceNM(to: coordinate) > 0.25 { self.aircraft = []; self.lastUpdate = nil }
            self.coordinate = coordinate
            if !self.locationHasFix { self.locationLabel = "Current location" }
            self.locationHasFix = true
            self.locationDetail = String(format: "Detected by macOS: %.4f, %.4f (±%.0f m).", coordinate.latitude, coordinate.longitude, fix.horizontalAccuracy)
            self.resolveCity(for: fix, coordinate: coordinate)
        }
    }

    private func resolveCity(for fix: CLLocation, coordinate: Coordinate) {
        guard geocodedCoordinate.map({ $0.distanceNM(to: coordinate) > 0.5 }) ?? true else { return }
        geocodingTask?.cancel()
        geocoder.cancelGeocode()
        geocodedCoordinate = coordinate
        geocodingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let placemark = try await self.geocoder.reverseGeocodeLocation(fix).first
                try Task.checkCancellation()
                guard self.useLocation, self.locationHasFix, self.geocodedCoordinate == coordinate else { return }
                if let city = placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.administrativeArea {
                    self.locationLabel = city
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.geocodedCoordinate = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.useLocation, !self.sleeping else { return }
            if (error as? CLError)?.code == .denied {
                self.useFallback("macOS has not granted location access. Open Location permissions, enable Location Services and Flight Notch, then choose Find my location.")
            } else if self.locationHasFix {
                self.locationDetail = "Location is temporarily unavailable. Using your last detected location while macOS tries again."
            } else {
                self.useFallback("macOS could not locate this Mac yet. Check Location permissions and turn on Wi-Fi, then choose Find my location. Jersey City is used in the meantime.")
            }
        }
    }
}
