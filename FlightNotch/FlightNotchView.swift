import MapKit
import SwiftUI

private let flightBlue = Color(red: 0.15, green: 0.36, blue: 0.92)

struct FlightNotchView: View {
    @ObservedObject var store: FlightStore
    @ObservedObject var interaction: NotchInteraction
    let showSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                cameraStrip
                if interaction.expanded {
                    FlightMapView(store: store, interaction: interaction, showSettings: showSettings)
                        .frame(height: 330)
                        .transition(.opacity)
                }
            }
            .frame(width: interaction.expanded ? interaction.expandedWidth : interaction.compactWidth)
            .background(.black)
            .clipShape(NotchShape(topCornerRadius: interaction.expanded ? 12 : 6, bottomCornerRadius: interaction.expanded ? 24 : 14))
            .shadow(color: .black.opacity(interaction.expanded ? 0.18 : 0.06), radius: interaction.expanded ? 14 : 3, y: 6)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.85), value: interaction.expanded)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var cameraStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "airplane").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.73, blue: 1))
                Text(interaction.expanded ? "FLIGHT NOTCH" : store.flights.first?.aircraft.displayName ?? "SCANNING")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(interaction.expanded ? 1 : 0).lineLimit(1)
            }.frame(maxWidth: .infinity)
            Color.clear.frame(width: interaction.notchWidth)
            HStack(spacing: 6) {
                Circle().fill(store.isFresh ? Color.green : Color.orange).frame(width: 5, height: 5)
                if store.paused { Text("Paused") }
                else if store.errorMessage != nil { Text("Retrying") }
                else if interaction.expanded { Text("\(store.flights.count) nearby") }
                else if let flight = store.flights.first { Text(String(format: "%.1f NM %@", flight.distance, flight.direction)) }
                else { Text(store.statusLabel) }
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white).frame(height: interaction.notchHeight)
        .contentShape(Rectangle()).onTapGesture { interaction.open() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Flight Notch. \(store.flights.count) aircraft nearby. \(store.statusLabel). Click to expand.")
        .accessibilityAddTraits(.isButton).accessibilityAction { interaction.open() }
    }
}

private struct FlightMapView: View {
    @ObservedObject var store: FlightStore
    @ObservedObject var interaction: NotchInteraction
    let showSettings: () -> Void
    @State private var camera: MapCameraPosition = .automatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var origin: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: store.coordinate.latitude, longitude: store.coordinate.longitude)
    }

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $camera, interactionModes: [.pan, .zoom], selection: $store.selectedID) {
                MapCircle(center: origin, radius: store.radius * 1852)
                    .foregroundStyle(flightBlue.opacity(0.02))
                    .stroke(flightBlue.opacity(store.satellite ? 0.45 : 0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                Annotation(store.locationLabel, coordinate: origin) {
                    Circle().fill(flightBlue).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .padding(6).background(flightBlue.opacity(0.13), in: Circle())
                        .accessibilityLabel(store.locationLabel)
                }.annotationTitles(.hidden)
                ForEach(store.flights) { flight in
                    if let point = flight.aircraft.coordinate {
                        Annotation(flight.aircraft.displayName, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                            Button { store.selectedID = flight.id } label: {
                                AircraftHeading(track: flight.aircraft.track, size: flight.aircraft.size, selected: flight.id == store.selectedFlight?.id)
                                    .frame(width: 40, height: 42)
                                    .contentShape(Rectangle())
                                    .overlay(alignment: .bottom) {
                                        Text(flight.aircraft.displayName)
                                            .font(.system(size: flight.id == store.selectedFlight?.id ? 9 : 8, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 2)
                                            .background(flight.id == store.selectedFlight?.id ? flightBlue : .black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                                            .fixedSize().offset(y: 12)
                                            .allowsHitTesting(false)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Select \(flight.aircraft.displayName), \(String(format: "%.1f", flight.distance)) nautical miles \(flight.direction)")
                            .help("\(flight.aircraft.displayName) · \(flight.aircraft.typeName) · \(String(format: "%.1f", flight.distance)) NM \(flight.direction)")
                        }.annotationTitles(.hidden).tag(flight.id)
                    }
                }
            }
            .mapStyle(store.satellite ? .imagery(elevation: .flat) : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls { }
            .overlay(alignment: .top) { mapToolbar.padding(10) }
            .frame(height: 220)
            .onAppear { recenter() }
            .onChange(of: store.radius) { _, _ in recenter() }
            .onChange(of: store.coordinate) { _, _ in
                if !camera.positionedByUser { recenter() }
            }

            VStack(spacing: 7) {
                if let flight = store.selectedFlight {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(flight.aircraft.displayName).font(.system(size: 16, weight: .bold, design: .rounded))
                            Text(flight.aircraft.typeName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                .help(flight.aircraft.typeName)
                            Text([flight.aircraft.typeCode, flight.aircraft.registration].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let route = store.selectedRoute, let origin = route.origin, let destination = route.destination {
                            if route.airports.count > 2 {
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text("ROUTE STOPS").font(.system(size: 8, weight: .medium)).tracking(0.5).foregroundStyle(.secondary)
                                    Text(route.airports.map(\.code).joined(separator: " → "))
                                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(flightBlue)
                                        .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: 170, alignment: .trailing)
                                    .help("Multi-stop itinerary from ADSB.im. The current leg is not confirmed.")
                            } else {
                                HStack(spacing: 10) {
                                    airport(origin, label: "DEPARTURE")
                                    Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(.secondary)
                                    airport(destination, label: "DESTINATION")
                                }.help("\(route.airports.map(\.name).joined(separator: " → ")). Route estimate from ADSB.im aircraft messages and historical tracks; diversions may differ.")
                            }
                        } else {
                            Text(store.selectedRouteMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 140, alignment: .trailing)
                        }
                    }
                    HStack(spacing: 12) {
                        Label(String(format: "%.1f NM %@", flight.distance, flight.direction), systemImage: "location")
                        Text(flight.aircraft.altitude.map { $0.formatted(.number.precision(.fractionLength(0))) + " ft" } ?? "Altitude —")
                        Text(flight.aircraft.speed.map { String(format: "%.0f kt", $0) } ?? "Speed —")
                        Spacer()
                        Label(flight.aircraft.phase.rawValue + " · est.", systemImage: flight.aircraft.phase.symbol)
                            .foregroundStyle(flightBlue)
                            .help("Phase estimated from altitude and vertical speed. Vertical speed: \(flight.aircraft.verticalRate.map { String(format: "%.0f ft/min", $0) } ?? "unknown").")
                    }.font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(emptyTitle).font(.system(size: 16, weight: .semibold, design: .rounded))
                            Text(emptyDetail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if store.hasFilters {
                            Button("Clear filters") { store.resetFilters() }.buttonStyle(.plain).font(.caption).foregroundStyle(flightBlue)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 4) {
                    if let via = store.selectedRoute?.via { Text("Via \(via)").lineLimit(1).help(via) }
                    if store.hasFilters { Text("Filtered") }
                    Spacer()
                    if store.errorMessage != nil || store.paused { Text(store.retryLabel).foregroundStyle(.orange) }
                    else { Text(store.ageLabel) }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
                    .help(store.errorMessage ?? "Aircraft positions update every 8 seconds. Satellite imagery is not live video. Detection stays centered on your location.")
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .frame(height: 110).background(.background)
        }
        .task(id: store.selectedFlight.map { "\($0.id):\($0.aircraft.callsign ?? "")" }) {
            while !Task.isCancelled {
                await store.loadSelectedRoute()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private var mapToolbar: some View {
        HStack(alignment: .top) {
            HStack(spacing: 6) {
                Circle().fill(store.locationHasFix ? .green : .orange).frame(width: 5, height: 5)
                Text(store.locationLabel).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule()).help(store.locationDetail)
            Spacer()
            HStack(spacing: 1) {
                mapButton("location", label: "Recenter map", action: recenter)
                mapButton(interaction.pinned ? "pin.fill" : "pin", label: interaction.pinned ? "Unpin notch" : "Keep notch open") { interaction.togglePin() }
                    .foregroundStyle(interaction.pinned ? flightBlue : .primary)
                mapButton("slider.horizontal.3", label: "Flight settings", action: showSettings)
            }.padding(3).background(.regularMaterial, in: Capsule())
        }
    }

    private func mapButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 27, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private func airport(_ airport: RouteAirport, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 8, weight: .medium)).tracking(0.5).foregroundStyle(.secondary)
            Text(airport.code).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(flightBlue)
            Text(airport.municipality ?? airport.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(width: 65, alignment: .leading)
    }

    private var emptyTitle: String {
        if store.paused { return "Tracking paused" }
        if store.errorMessage != nil { return "Waiting for the feed" }
        if store.lastUpdate == nil { return "Finding nearby aircraft…" }
        return store.hasFilters ? "No matching aircraft" : "A quiet patch of sky"
    }

    private var emptyDetail: String {
        if store.paused { return "Resume tracking in Settings." }
        if let error = store.errorMessage { return error }
        if store.hasFilters { return "Adjust your filters or detection radius in Settings." }
        return "Aircraft appear as they enter your \(Int(store.radius)) NM detection radius."
    }

    private func recenter() {
        let region = MKCoordinateRegion(center: origin, latitudinalMeters: store.radius * 1852 * 2.65, longitudinalMeters: store.radius * 1852 * 2.65)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { camera = .region(region) }
    }
}

private struct AircraftHeading: View {
    let track: Double?
    let size: AircraftSize
    let selected: Bool
    @State private var heading: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AircraftSilhouette()
            .fill(selected ? flightBlue : .white)
            .overlay(AircraftSilhouette().stroke(selected ? .white : Color(red: 0.08, green: 0.18, blue: 0.34), lineWidth: 1))
            .frame(width: size.markerLength * 0.86, height: size.markerLength)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .rotationEffect(.degrees(heading))
            .onAppear { heading = track ?? 0 }
            .onChange(of: track) { _, newValue in
                guard let newValue else { return }
                let normalized = (heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                let delta = (newValue - normalized + 540).truncatingRemainder(dividingBy: 360) - 180
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) { heading += delta }
            }
    }
}

private struct AircraftSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        // Top-down jet: rounded nose, swept wings, fuselage and tailplane.
        let points: [CGPoint] = [
            .init(x: 0.56, y: 0.13), .init(x: 0.57, y: 0.37),
            .init(x: 0.96, y: 0.61), .init(x: 0.96, y: 0.69),
            .init(x: 0.57, y: 0.55), .init(x: 0.55, y: 0.82),
            .init(x: 0.70, y: 0.92), .init(x: 0.70, y: 0.98),
            .init(x: 0.50, y: 0.93), .init(x: 0.30, y: 0.98),
            .init(x: 0.30, y: 0.92), .init(x: 0.45, y: 0.82),
            .init(x: 0.43, y: 0.55), .init(x: 0.04, y: 0.69),
            .init(x: 0.04, y: 0.61), .init(x: 0.43, y: 0.37),
            .init(x: 0.44, y: 0.13)
        ]
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.50, 0.01))
        path.addQuadCurve(to: point(0.56, 0.13), control: point(0.56, 0.04))
        for p in points.dropFirst() { path.addLine(to: point(p.x, p.y)) }
        path.addQuadCurve(to: point(0.50, 0.01), control: point(0.44, 0.04))
        path.closeSubpath()
        return path
    }
}

struct FlightSettingsView: View {
    @ObservedObject var store: FlightStore
    @ObservedObject var interaction: NotchInteraction

    var body: some View {
        Form {
            Section("Notch") {
                Picker("Visibility", selection: $interaction.pinned) {
                    Text("Auto-hide").tag(false)
                    Text("Always open").tag(true)
                }.pickerStyle(.segmented)
                if !interaction.pinned {
                    Picker("Hide after", selection: $interaction.hideDelay) {
                        ForEach([3.0, 5.0, 10.0, 30.0], id: \.self) { delay in
                            Text("\(Int(delay)) seconds").tag(delay)
                        }
                    }
                }
                Text(interaction.pinned ? "The map stays expanded. The pin button switches back to auto-hide." : "The map collapses to the compact strip after the pointer leaves. Hover or click to reopen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Map") {
                Picker("Appearance", selection: $store.satellite) {
                    Text("Map").tag(false)
                    Text("Satellite").tag(true)
                }.pickerStyle(.segmented)
                Text("Satellite imagery with live aircraft positions. Pan and zoom freely; detection stays centered on your location.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Detection") {
                HStack {
                    Slider(value: $store.radius, in: 2...25, step: 1) { Text("Radius") }
                    Text("\(Int(store.radius)) NM").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
                TextField("Airline ICAO prefixes", text: $store.airline, prompt: Text("UAL, DAL, AAL"))
                Text("Leave blank for all airlines. Separate callsign prefixes with commas; regional partners may use a different prefix.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Aircraft", selection: $store.aircraftClass) {
                    ForEach(AircraftClass.allCases) { type in Text(type.rawValue).tag(type) }
                }
            }
            Section("Location") {
                Toggle("Use my current location", isOn: $store.useLocation)
                Text(store.locationDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.useLocation {
                    HStack {
                        Button("Find my location") { store.refreshLocation() }
                        Spacer()
                        Button("Location permissions…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                        }
                    }.font(.caption)
                }
            }
            Section("Live feed") {
                Picker("Provider", selection: $store.provider) {
                    ForEach(FeedProvider.allCases) { provider in
                        Text(provider == .adsbFi ? "adsb.fi (recommended)" : provider.rawValue).tag(provider)
                    }
                }
                Text(store.provider == .adsbFi
                     ? "adsb.fi allows 1 request/second for personal, non-commercial use. Flight Notch requests every 8 seconds."
                     : "adsb.lol uses dynamic rate limits. Flight Notch requests every 8 seconds and backs off when asked.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(store.statusLabel).foregroundStyle(store.isFresh ? .green : .secondary)
                    Spacer()
                    Button(store.paused ? "Resume tracking" : "Pause tracking") { store.setPaused(!store.paused) }
                }
                if store.errorMessage != nil {
                    Text("\(store.errorMessage!) \(store.retryLabel).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Link("Data: \(store.provider.rawValue) ↗", destination: store.provider.website)
                    Link("Routes: ADSB.im ↗", destination: URL(string: "https://adsb.im/using")!)
                    Spacer()
                    Button("Reset filters") { store.resetFilters(); store.radius = 5 }
                }.font(.caption)
                Text("Distances are horizontal nautical miles. Aircraft types and flight phases are estimates. Positions older than 60 seconds are hidden; coverage varies.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Routes use ADSB.im aircraft messages and historical tracks; coverage and diversions vary. No route history is saved. Icon sizes use aircraft type and ADS-B size category, not exact scale.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 680)
    }
}
