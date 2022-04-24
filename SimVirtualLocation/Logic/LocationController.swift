//
//  LocationController.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.02.2022.
//

import Combine
import CoreLocation
import MapKit
import MachO

class LocationController: NSObject, ObservableObject, MKMapViewDelegate, CLLocationManagerDelegate {

    enum DeviceMode: Int, Identifiable {
        case simulator
        case device

        var id: Int { self.rawValue }
    }

    enum PointsMode: Int, Identifiable {
        case single
        case two

        var id: Int { self.rawValue }
    }

    private let mapView: MapView
    private let currentSimulationAnnotation = MKPointAnnotation()

    private let locationManager = CLLocationManager()
    private let simulationQueue = DispatchQueue(label: "simulation", qos: .utility)

    private var isMapCentered = false
    private var annotations: [MKAnnotation] = []
    private var route: MKRoute?
    private var isSimulating = false
    
    private let defaults: UserDefaults = UserDefaults.standard

    @Published var speed: Double = 60.0
    @Published var pointsMode: PointsMode = .single {
        didSet { handlePointsModeChange() }
    }
    @Published var deviceMode: DeviceMode = .simulator

    @Published var bootedSimulators: [Simulator] = []
    @Published var selectedSimulator: String = ""

    @Published var connectedDevices: [Device] = []
    @Published var selectedDevice: String = ""

    @Published var showingAlert: Bool = false
    @Published var deviceType: Int = 0
    @Published var adbPath: String = ""
    @Published var adbDeviceId: String = ""
    
    var alertText: String = ""

    private var timeScale: Double = 1
    
    private var tracks: [Track] = []
    private var currentTrackIndex: Int = 0
    private var lastTrackLocation: CLLocationCoordinate2D?
    private var timer: Timer?

    init(mapView: MapView) {
        self.mapView = mapView
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone

        mapView.mkMapView.delegate = self
        mapView.clickAction = handleMapClick

        refreshDevices()
        
        deviceType = defaults.integer(forKey: "device_type")
        adbPath = defaults.string(forKey: "adb_path") ?? ""
        adbDeviceId = defaults.string(forKey: "adb_device_id") ?? ""
    }

    func refreshDevices() {
        bootedSimulators = (try? getBootedSimulators()) ?? []
        selectedSimulator = bootedSimulators.first?.id ?? ""

        connectedDevices = (try? getConnectedDevices()) ?? []
        selectedDevice = connectedDevices.first?.id ?? ""
    }

    func setCurrentLocation() {
        guard let location = locationManager.location?.coordinate else {
            showAlert("Current location is unavailable")
            return
        }
        run(location: location)
    }

    func setSelectedLocation() {
        guard let annotation = annotations.first else {
            showAlert("Point A is not selected")
            return
        }
        run(location: annotation.coordinate)
    }

    func makeRoute() {
        guard annotations.count == 2 else {
            showAlert("Route requires two points")
            return
        }

        let startPoint = annotations[0].coordinate
        let endPoint = annotations[1].coordinate

        let sourcePlacemark = MKPlacemark(coordinate: startPoint, addressDictionary: nil)
        let destinationPlacemark = MKPlacemark(coordinate: endPoint, addressDictionary: nil)

        let sourceMapItem = MKMapItem(placemark: sourcePlacemark)
        let destinationMapItem = MKMapItem(placemark: destinationPlacemark)

        let sourceAnnotation = MKPointAnnotation()

        if let location = sourcePlacemark.location {
            sourceAnnotation.coordinate = location.coordinate
        }

        let destinationAnnotation = MKPointAnnotation()

        if let location = destinationPlacemark.location {
            destinationAnnotation.coordinate = location.coordinate
        }

        self.mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        self.mapView.mkMapView.showAnnotations([sourceAnnotation, destinationAnnotation], animated: true )

        let directionRequest = MKDirections.Request()
        directionRequest.source = sourceMapItem
        directionRequest.destination = destinationMapItem
        directionRequest.transportType = .automobile

        let directions = MKDirections(request: directionRequest)

        directions.calculate { (response, error) -> Void in
            guard let response = response else {
                if let error = error {
                    self.showAlert(error.localizedDescription)
                }
                return
            }

            let route = response.routes[0]

            if let currentRoute = self.route {
                self.mapView.mkMapView.removeOverlay(currentRoute.polyline)
            }
            self.route = route
            self.tracks = []
            self.mapView.mkMapView.addOverlay((route.polyline), level: MKOverlayLevel.aboveRoads)

            let rect = route.polyline.boundingMapRect
            self.mapView.mkMapView.setRegion(MKCoordinateRegion(rect.insetBy(dx: -1000, dy: -1000)), animated: true)
        }
    }

    func simulateRoute() {
        simulateRouteV2()
    }
    
    func simulateRouteV2() {
        self.runRouteSimulation()
    }
    
    private func runRouteSimulation() {
        guard let route = route else {
            showAlert("No route for simulation")
            return
        }
        
        let buffer = UnsafeBufferPointer(start: route.polyline.points(), count: route.polyline.pointCount)
        
        for i in 0..<route.polyline.pointCount {
            let trackStartPoint = buffer[i]
            var trackEndPoint: MKMapPoint?
            if i + 1 < route.polyline.pointCount {
                trackEndPoint = buffer[i+1]
            }
            
            if let trackEndPoint = trackEndPoint {
                tracks.append(Track(startPoint: trackStartPoint, endPoint: trackEndPoint))
            }
        }
        
        // prints all tracks distances
        print(tracks.map { CLLocation.distance(from: $0.startPoint.coordinate, to: $0.endPoint.coordinate) })
        
        timer?.invalidate()
        isSimulating = true
        lastTrackLocation = nil
        currentTrackIndex = 0
        
        let timer = Timer.scheduledTimer(withTimeInterval: timeScale, repeats: true) { timer in
            guard self.isSimulating, self.tracks.count > 0, self.currentTrackIndex < self.tracks.count else {
                self.isSimulating = false
                self.timer = nil
                self.currentTrackIndex = 0
                timer.invalidate()
                return
            }
            
            let track = self.tracks[self.currentTrackIndex]
            let trackMove = track.getNextLocation(
                from: self.lastTrackLocation,
                speed: (self.speed / 3.6) * self.timeScale
            )
            
            print()
            
            switch trackMove {
            case .moveTo(let to, let from, let speed):
                self.lastTrackLocation = to
                self.run(location: to)
                self.mapView.mkMapView.removeAnnotation(self.currentSimulationAnnotation)
                self.currentSimulationAnnotation.coordinate = to
                self.mapView.mkMapView.addAnnotation(self.currentSimulationAnnotation)
                print("move to - distance=\(CLLocation.distance(from: from, to: to)), speed=\(speed)")
                
            case .finishTo(let to, let from, let speed):
                self.lastTrackLocation = nil
                self.currentTrackIndex += 1
                self.run(location: to)
                self.mapView.mkMapView.removeAnnotation(self.currentSimulationAnnotation)
                self.currentSimulationAnnotation.coordinate = to
                self.mapView.mkMapView.addAnnotation(self.currentSimulationAnnotation)
                print("finish to - distance=\(CLLocation.distance(from: from, to: to)), speed=\(speed)")
            }
        }
        
        self.timer = timer
    }

    func updateMapRegion(force: Bool = false) {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return
        }

        guard !isMapCentered || force, let location = locationManager.location else { return }

        isMapCentered = true

        mapView.mkMapView.showsUserLocation = true

        let viewRegion = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000)
        let adjustedRegion = mapView.mkMapView.regionThatFits(viewRegion)

        mapView.mkMapView.setRegion(adjustedRegion, animated: true)
    }
    
    func installHelperApp() {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }
        
        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }
        
        let apkPath = Bundle.main.url(forResource: "helper-app", withExtension: "apk")!.path
        
        let path = adbPath
        let args = ["-s", adbDeviceId, "install", apkPath]

        let task = Process()
        task.executableURL = URL(string: "file://\(path)")!
        task.arguments = args

        let errorPipe = Pipe()

        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            showAlert(error.localizedDescription)
            return
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let error = String(decoding: errorData, as: UTF8.self)

        if !error.isEmpty {
            showAlert(error)
        } else {
            showAlert("Helper app successfully installed. Please open MockLocationForDeveloper app on your phone and grant all required permissions")
        }
    }

    func stopSimulation() {
        isSimulating = false
    }

    func reset() {
        resetAll()
    }

    private func handlePointsModeChange() {
        if pointsMode == .single && annotations.count == 2, let second = annotations.last {
            mapView.mkMapView.removeAnnotation(second)

            if let route = route {
                mapView.mkMapView.removeOverlay(route.polyline)
            }

            annotations = [annotations[0]]
        }
    }

    private func handleMapClick(_ sender: NSClickGestureRecognizer) {
        let point = sender.location(in: mapView.mkMapView)
        handleSet(point: point)
    }

    private func handleSet(point: CGPoint) {
        let clickLocation = mapView.mkMapView.convert(point, toCoordinateFrom: mapView.mkMapView)

        if pointsMode == .single {
            mapView.mkMapView.removeAnnotations(annotations)
            annotations = []
        }

        if annotations.count == 2 {
            mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
            annotations = []
            return
        }

        let annotation = MKPointAnnotation()
        annotation.coordinate = clickLocation
        annotation.title = annotations.count == 0 ? "A" : "B"

        annotations.append(annotation)
        self.mapView.mkMapView.addAnnotation(annotation)
    }

    private func run(location: CLLocationCoordinate2D) {
        defaults.set(deviceType, forKey: "device_type")
        defaults.set(adbPath, forKey: "adb_path")
        defaults.set(adbDeviceId, forKey: "adb_device_id")
        
        if deviceType != 0 {
            do {
                try runOnAndroid(location: location)
            } catch {
                showAlert("\(error)")
            }
            return
        }
        if deviceMode == .simulator {
            do {
                try runOnSimulator(location: location)
            } catch {
                showAlert("\(error)")
            }
            return
        }
        
        let task = taskForIOS(args: ["--", "\(location.latitude)", "\(location.longitude)"], selectedDevice: selectedDevice)
        let errorPipe = Pipe()

        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            showAlert(error.localizedDescription)
            return
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let error = String(decoding: errorData, as: UTF8.self)

        if !error.isEmpty {
            showAlert(error + """
            
            Try to install: `brew install libimobiledevice`
            """)
        }
    }

    private func runOnSimulator(location: CLLocationCoordinate2D) throws {
        if bootedSimulators.isEmpty {
            isSimulating = false
            throw SimulatorFetchError.noBootedSimulators
        }

        let simulators = bootedSimulators
            .filter { $0.id == selectedSimulator || selectedSimulator == "" }
            .map { $0.id }

        NotificationSender.postNotification(for: location, to: simulators)
    }
    
    private func runOnAndroid(location: CLLocationCoordinate2D) throws {
        if adbDeviceId.isEmpty {
            showAlert("Please specify device id")
            return
        }
        
        if adbPath.isEmpty {
            showAlert("Please specify path to adb")
            return
        }
        
        let task = taskForAndroid(
            args: [
                "-s", adbDeviceId,
                "shell", "am", "broadcast",
                "-a", "send.mock",
                "-e", "lat", "\(location.latitude)",
                "-e", "lon", "\(location.longitude)"
            ]
        )

        let errorPipe = Pipe()

        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            showAlert(error.localizedDescription)
            return
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let error = String(decoding: errorData, as: UTF8.self)

        if !error.isEmpty {
            showAlert(error)
        }
    }
    
    private func taskForIOS(args: [String], selectedDevice: String?) -> Process {
        let path: URL = Bundle.main.url(forResource: "idevicelocation", withExtension: nil)!
        
        var args = args
        if let selectedDevice = selectedDevice, selectedDevice != "" {
            args = ["-u", selectedDevice] + args
        }

        let task = Process()
        task.executableURL = path
        task.arguments = args
        
        return task
    }
    
    private func taskForAndroid(args: [String]) -> Process {
        let path = adbPath
        let task = Process()
        task.executableURL = URL(string: "file://\(path)")!
        task.arguments = args
        
        return task
    }

    private func resetAll() {
        mapView.mkMapView.removeAnnotations(mapView.mkMapView.annotations)
        annotations = []

        if let route = route {
            mapView.mkMapView.removeOverlay(route.polyline)
        }

        let task: Process
        
        if deviceType == 0 {
            task = taskForIOS(args: ["-s"], selectedDevice: nil)
        } else {
            task = taskForAndroid(
                args: [
                    "-s", adbDeviceId,
                    "shell", "am", "broadcast",
                    "-a", "stop.mock"
                ]
            )
        }
        
        let errorPipe = Pipe()

        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            showAlert(error.localizedDescription)
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let error = String(decoding: errorData, as: UTF8.self)

        if !error.isEmpty {
            showAlert(error)
        }

        task.waitUntilExit()
    }

    private func showAlert(_ text: String) {
        alertText = text
        showingAlert = true
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let renderer = MKPolylineRenderer(overlay: overlay)
        renderer.strokeColor = NSColor(red: 17.0/255.0, green: 147.0/255.0, blue: 255.0/255.0, alpha: 1)
        renderer.lineWidth = 5.0
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation === currentSimulationAnnotation {
            let marker = MKMarkerAnnotationView(
                annotation: currentSimulationAnnotation,
                reuseIdentifier: "simulationMarker"
            )
            marker.markerTintColor = .orange
            return marker
        }
        return nil
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        updateMapRegion()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateMapRegion()
    }
}

private extension LocationController {

    private func getConnectedDevices() throws -> [Device] {
        let task = Process()
        task.launchPath = "/usr/bin/xcrun"
        task.arguments = ["xctrace", "list", "devices"]

        let pipe = Pipe()
        task.standardOutput = pipe

        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        pipe.fileHandleForReading.closeFile()

        if task.terminationStatus != 0 {
            throw SimulatorFetchError.simctlFailed
        }

        let output = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .filter { ($0.contains("iPhone") || $0.contains("iPad")) && !$0.contains("Simulator") }

        var connectedDevices: [Device] = []
        output?.forEach { line in
            let udid = "\(line)"
                .split(separator: " ")
                .last?
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
            
            if let udid = udid {
                connectedDevices.append(Device(id: udid, name: "\(line)"))
            }
        }

        return connectedDevices
    }

    private func getBootedSimulators() throws -> [Simulator] {
        let task = Process()
        task.launchPath = "/usr/bin/xcrun"
        task.arguments = ["simctl", "list", "-j", "devices"]

        let pipe = Pipe()
        task.standardOutput = pipe

        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        pipe.fileHandleForReading.closeFile()

        if task.terminationStatus != 0 {
            throw SimulatorFetchError.simctlFailed
        }

        let bootedSimulators: [Simulator]

        do {
            bootedSimulators = try JSONDecoder().decode(Simulators.self, from: data).bootedSimulators
        } catch {
            throw SimulatorFetchError.failedToReadOutput
        }

        if bootedSimulators.isEmpty {
            throw SimulatorFetchError.noBootedSimulators
        }

        return [Simulator.empty()] + bootedSimulators
    }

    enum SimulatorFetchError: Error, CustomStringConvertible {
        case simctlFailed
        case failedToReadOutput
        case noBootedSimulators
        case noMatchingSimulators(name: String)
        case noMatchingUDID(udid: UUID)

        var description: String {
            switch self {
            case .simctlFailed:
                return "Running `simctl list` failed"
            case .failedToReadOutput:
                return "Failed to read output from simctl"
            case .noBootedSimulators:
                return "No simulators are currently booted"
            case .noMatchingSimulators(let name):
                return "No booted simulators named '\(name)'"
            case .noMatchingUDID(let udid):
                return "No booted simulators with udid: \(udid.uuidString)"
            }
        }
    }
}

extension CLLocation {

    static func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        let from = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let to = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return from.distance(from: to)
    }
}