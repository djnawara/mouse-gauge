import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

private enum ReportProtocol: Sendable {
    case feature
    case interrupt
    case automatic
}

private struct ProductInfo: Sendable {
    let name: String
    let reportProtocol: ReportProtocol
}

private struct BatteryReading: Sendable {
    enum State: Sendable {
        case active
        case sleeping
        case noPermission
        case noDevice
        case noResponse
        case error
    }

    let state: State
    let percent: Int?
    let charging: Bool
    let deviceName: String?
    let productID: Int?
    let detail: String
}

private struct HIDCandidate {
    let device: IOHIDDevice
    let productID: Int
    let productName: String
    let manufacturer: String?
    let transport: String?
    let locationID: Int?
    let usagePage: Int
    let usage: Int
}

private final class WLMouseBatteryReader {
    static let vendorID = 0x36A7

    private static let knownProducts: [Int: ProductInfo] = [
        0xA860: ProductInfo(name: "WLMouse Receiver", reportProtocol: .feature),
        0xA866: ProductInfo(name: "Miao 8K Receiver", reportProtocol: .feature),
        0xA867: ProductInfo(name: "Miao", reportProtocol: .feature),
        0xA868: ProductInfo(name: "Beast X Mini Pro", reportProtocol: .feature),
        0xA870: ProductInfo(name: "Beast X Pro 8K Receiver", reportProtocol: .feature),
        0xA878: ProductInfo(name: "Sword X 8K Receiver", reportProtocol: .feature),
        0xA880: ProductInfo(name: "Beast MAX 8K Receiver", reportProtocol: .feature),
        0xA883: ProductInfo(name: "Beast X 8K Receiver", reportProtocol: .feature),
        0xA884: ProductInfo(name: "Beast X 8K", reportProtocol: .feature),
        0xA885: ProductInfo(name: "Beast X Mini Receiver", reportProtocol: .feature),
        0xA887: ProductInfo(name: "Beast X Receiver", reportProtocol: .interrupt),
        0xA888: ProductInfo(name: "Beast X", reportProtocol: .interrupt)
    ]

    func readBattery() -> BatteryReading {
        guard HIDAccess.hasListenAccess else {
            return BatteryReading(
                state: .noPermission,
                percent: nil,
                charging: false,
                deviceName: nil,
                productID: nil,
                detail: "Input Monitoring permission is required for HID access"
            )
        }

        let candidates = enumerateCandidates()

        guard !candidates.isEmpty else {
            return BatteryReading(
                state: .noDevice,
                percent: nil,
                charging: false,
                deviceName: nil,
                productID: nil,
                detail: "No WLMouse HID devices found"
            )
        }

        var lastDetail = "No battery response"
        var sleepingReading: BatteryReading?

        for candidate in candidatesForQuery(candidates) {
            let product = Self.knownProducts[candidate.productID]
            let protocols = protocolsToTry(for: product)

            for reportProtocol in protocols {
                let outcome: ProbeOutcome
                switch reportProtocol {
                case .feature:
                    outcome = queryFeature(candidate)
                case .interrupt:
                    outcome = queryInterrupt(candidate)
                case .automatic:
                    continue
                }

                switch outcome {
                case let .active(percent, charging):
                    return reading(
                        state: .active,
                        candidate: candidate,
                        percent: percent,
                        charging: charging,
                        detail: "Battery read via \(reportProtocol.label.lowercased()) report"
                    )
                case .sleeping:
                    sleepingReading = sleepingReading ?? reading(
                        state: .sleeping,
                        candidate: candidate,
                        percent: nil,
                        charging: false,
                        detail: "Receiver replied, continuing to look for an active mouse collection"
                    )
                case let .noResponse(detail):
                    lastDetail = detail
                case let .error(detail):
                    lastDetail = detail
                }
            }
        }

        if let sleepingReading {
            return sleepingReading
        }

        return BatteryReading(
            state: .noResponse,
            percent: nil,
            charging: false,
            deviceName: candidates.first.map(deviceDisplayName),
            productID: candidates.first?.productID,
            detail: lastDetail
        )
    }

    func describeDevices() -> [String] {
        guard HIDAccess.hasListenAccess else {
            return ["Input Monitoring permission is required for HID access"]
        }

        let candidates = candidatesForQuery(enumerateCandidates())
        guard !candidates.isEmpty else {
            return ["No WLMouse HID collections found for VID 0x36A7"]
        }

        return candidates.enumerated().map { index, candidate in
            let product = Self.knownProducts[candidate.productID]
            let protocolName = product?.reportProtocol.label ?? "Automatic"
            let manufacturer = candidate.manufacturer ?? "unknown manufacturer"
            let transport = candidate.transport ?? "unknown transport"
            let location = candidate.locationID.map(hex) ?? "unknown location"

            return """
            [\(index + 1)] \(deviceDisplayName(candidate))
                PID: \(hex(candidate.productID))
                Product string: \(candidate.productName)
                Manufacturer: \(manufacturer)
                Transport: \(transport)
                Location: \(location)
                Usage page: \(hex(candidate.usagePage))
                Usage: \(hex(candidate.usage))
                Protocol: \(protocolName)
            """
        }
    }

    func probeDevices() -> [String] {
        guard HIDAccess.hasListenAccess else {
            return ["Input Monitoring permission is required for HID access"]
        }

        let candidates = candidatesForQuery(enumerateCandidates())
        guard !candidates.isEmpty else {
            return ["No WLMouse HID collections found for VID 0x36A7"]
        }

        var lines: [String] = []
        for (index, candidate) in candidates.enumerated() {
            lines.append("[\(index + 1)] \(deviceDisplayName(candidate)) \(hex(candidate.productID)) usagePage=\(hex(candidate.usagePage)) usage=\(hex(candidate.usage))")
            lines.append(contentsOf: probeFeature(candidate))
        }
        return lines
    }

    private func enumerateCandidates() -> [HIDCandidate] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [kIOHIDVendorIDKey: Self.vendorID] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)

        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            return []
        }
        defer {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
            return []
        }

        return (deviceSet as NSSet).compactMap { item in
            let device = item as! IOHIDDevice
            guard intProperty(device, kIOHIDProductIDKey) != nil else {
                return nil
            }

            let productID = intProperty(device, kIOHIDProductIDKey) ?? 0
            let productName = stringProperty(device, kIOHIDProductKey) ?? "WLMouse"
            return HIDCandidate(
                device: device,
                productID: productID,
                productName: productName,
                manufacturer: stringProperty(device, kIOHIDManufacturerKey),
                transport: stringProperty(device, kIOHIDTransportKey),
                locationID: intProperty(device, kIOHIDLocationIDKey),
                usagePage: intProperty(device, kIOHIDPrimaryUsagePageKey) ?? 0,
                usage: intProperty(device, kIOHIDPrimaryUsageKey) ?? 0
            )
        }
    }

    private func candidatesForQuery(_ candidates: [HIDCandidate]) -> [HIDCandidate] {
        candidates.sorted { lhs, rhs in
            let lhsKnown = Self.knownProducts[lhs.productID] == nil ? 1 : 0
            let rhsKnown = Self.knownProducts[rhs.productID] == nil ? 1 : 0
            if lhsKnown != rhsKnown {
                return lhsKnown < rhsKnown
            }

            let lhsRank = rank(lhs)
            let rhsRank = rank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            return lhs.productID < rhs.productID
        }
    }

    private func rank(_ candidate: HIDCandidate) -> Int {
        if candidate.usagePage == 0xFFFF && candidate.usage == 0 {
            return 0
        }
        if candidate.usagePage == 0xFFFF {
            return 1
        }
        if candidate.usagePage >= 0xFF00 {
            return 2
        }
        if candidate.usage == 0x06 {
            return 3
        }
        return 10
    }

    private func protocolsToTry(for product: ProductInfo?) -> [ReportProtocol] {
        switch product?.reportProtocol ?? .automatic {
        case .feature:
            return [.feature]
        case .interrupt:
            return [.interrupt]
        case .automatic:
            return [.feature, .interrupt]
        }
    }

    private enum ProbeOutcome {
        case active(percent: Int, charging: Bool)
        case sleeping
        case noResponse(String)
        case error(String)
    }

    private struct FeatureRequest {
        let name: String
        let reportID: Int
        let bytes: [UInt8]
    }

    private func queryFeature(_ candidate: HIDCandidate) -> ProbeOutcome {
        let openStatus = IOHIDDeviceOpen(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            return .error("Could not open \(deviceDisplayName(candidate)): \(ioReturnString(openStatus))")
        }
        defer {
            IOHIDDeviceClose(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        var lastError: String?

        for request in featureRequests() {
            for _ in 0..<3 {
                let sendStatus = request.bytes.withUnsafeBufferPointer { buffer in
                    IOHIDDeviceSetReport(
                        candidate.device,
                        kIOHIDReportTypeFeature,
                        CFIndex(request.reportID),
                        buffer.baseAddress!,
                        request.bytes.count
                    )
                }

                if sendStatus != kIOReturnSuccess {
                    lastError = "Feature request failed for \(deviceDisplayName(candidate)) using \(request.name): \(ioReturnString(sendStatus))"
                    continue
                }

                Thread.sleep(forTimeInterval: 0.12)

                var response = [UInt8](repeating: 0, count: 65)
                var responseLength = CFIndex(response.count)
                let readStatus = response.withUnsafeMutableBufferPointer { buffer in
                    IOHIDDeviceGetReport(
                        candidate.device,
                        kIOHIDReportTypeFeature,
                        CFIndex(request.reportID),
                        buffer.baseAddress!,
                        &responseLength
                    )
                }

                if readStatus != kIOReturnSuccess {
                    lastError = "Feature response failed for \(deviceDisplayName(candidate)) using \(request.name): \(ioReturnString(readStatus))"
                    continue
                }

                if let parsed = parseFeatureResponse(response, length: Int(responseLength)) {
                    return parsed
                }
            }
        }

        if let lastError {
            return .error(lastError)
        }

        return .noResponse("Feature report did not contain a battery response")
    }

    private func probeFeature(_ candidate: HIDCandidate) -> [String] {
        let openStatus = IOHIDDeviceOpen(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            return ["    open: \(ioReturnString(openStatus))"]
        }
        defer {
            IOHIDDeviceClose(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        return featureRequests().map { request in
            let sendStatus = request.bytes.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(
                    candidate.device,
                    kIOHIDReportTypeFeature,
                    CFIndex(request.reportID),
                    buffer.baseAddress!,
                    request.bytes.count
                )
            }

            Thread.sleep(forTimeInterval: 0.12)

            var response = [UInt8](repeating: 0, count: 65)
            var responseLength = CFIndex(response.count)
            let readStatus = response.withUnsafeMutableBufferPointer { buffer in
                IOHIDDeviceGetReport(
                    candidate.device,
                    kIOHIDReportTypeFeature,
                    CFIndex(request.reportID),
                    buffer.baseAddress!,
                    &responseLength
                )
            }

            let prefix = response.prefix(min(Int(responseLength), 16)).map { String(format: "%02X", $0) }.joined(separator: " ")
            return "    feature \(request.name): set=\(ioReturnString(sendStatus)) get=\(ioReturnString(readStatus)) len=\(responseLength) bytes=\(prefix)"
        }
    }

    private func featureRequests() -> [FeatureRequest] {
        var hidapiStyle = [UInt8](repeating: 0, count: 65)
        hidapiStyle[3] = 0x02
        hidapiStyle[4] = 0x02
        hidapiStyle[6] = 0x83

        var payloadOnly = [UInt8](repeating: 0, count: 64)
        payloadOnly[2] = 0x02
        payloadOnly[3] = 0x02
        payloadOnly[5] = 0x83

        return [
            FeatureRequest(name: "65-byte report-id-prefixed", reportID: 0, bytes: hidapiStyle),
            FeatureRequest(name: "64-byte payload-only", reportID: 0, bytes: payloadOnly)
        ]
    }

    private func parseFeatureResponse(_ response: [UInt8], length: Int) -> ProbeOutcome? {
        let layouts = [
            (status: 1, command: 6, charging: 7, battery: 8),
            (status: 0, command: 5, charging: 6, battery: 7)
        ]

        for layout in layouts where length > layout.battery {
            guard response[layout.command] == 0x83 else {
                continue
            }

            if response[layout.status] == 0xA1 || response[layout.status] == 0xA2 {
                let percent = Int(response[layout.battery])
                guard (0...100).contains(percent) else {
                    return .noResponse("Feature battery value out of range: \(percent)")
                }
                return .active(percent: percent, charging: response[layout.charging] == 0x01)
            }

            if response[layout.status] == 0xA0 {
                return .sleeping
            }
        }

        return nil
    }

    private func queryInterrupt(_ candidate: HIDCandidate) -> ProbeOutcome {
        let openStatus = IOHIDDeviceOpen(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else {
            return .error("Could not open \(deviceDisplayName(candidate)): \(ioReturnString(openStatus))")
        }
        defer {
            IOHIDDeviceClose(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        for reportID in [0x04, 0x00] {
            var request = [UInt8](repeating: 0, count: 64)
            request[0] = 0x04
            request[3] = 0x1A

            let sendStatus = request.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(
                    candidate.device,
                    kIOHIDReportTypeOutput,
                    CFIndex(reportID),
                    buffer.baseAddress!,
                    request.count
                )
            }

            guard sendStatus == kIOReturnSuccess else {
                continue
            }

            Thread.sleep(forTimeInterval: 0.12)

            for inputReportID in [0x00, 0x04] {
                var response = [UInt8](repeating: 0, count: 64)
                var responseLength = CFIndex(response.count)
                let readStatus = response.withUnsafeMutableBufferPointer { buffer in
                    IOHIDDeviceGetReport(
                        candidate.device,
                        kIOHIDReportTypeInput,
                        CFIndex(inputReportID),
                        buffer.baseAddress!,
                        &responseLength
                    )
                }

                guard readStatus == kIOReturnSuccess, responseLength >= 10 else {
                    continue
                }

                let percent = Int(response[8])
                if (1...100).contains(percent) {
                    return .active(percent: percent, charging: false)
                }
            }
        }

        return .noResponse("Interrupt report did not contain a battery response")
    }

    private func reading(
        state: BatteryReading.State,
        candidate: HIDCandidate,
        percent: Int?,
        charging: Bool,
        detail: String
    ) -> BatteryReading {
        BatteryReading(
            state: state,
            percent: percent,
            charging: charging,
            deviceName: deviceDisplayName(candidate),
            productID: candidate.productID,
            detail: detail
        )
    }

    private func deviceDisplayName(_ candidate: HIDCandidate) -> String {
        if let product = Self.knownProducts[candidate.productID] {
            return product.name
        }
        return candidate.productName
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else {
            return nil
        }
        return value as? String
    }

    private func ioReturnString(_ value: IOReturn) -> String {
        String(format: "0x%08X", value)
    }

    private func hex(_ value: Int) -> String {
        String(format: "0x%04X", value)
    }
}

private extension ReportProtocol {
    var label: String {
        switch self {
        case .feature:
            return "Feature"
        case .interrupt:
            return "Interrupt"
        case .automatic:
            return "Automatic"
        }
    }
}

private enum HIDAccess {
    static var hasListenAccess: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightListenEventAccess()
        }
        return true
    }

    @discardableResult
    static func requestListenAccess() -> Bool {
        if #available(macOS 10.15, *) {
            return CGRequestListenEventAccess()
        }
        return true
    }
}

private enum StatusIcon {
    static func make(percent: Int?, charging: Bool, state: BatteryReading.State) -> NSImage {
        let size = NSSize(width: 27, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, percent: percent, charging: charging, state: state)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(in rect: NSRect, percent: Int?, charging: Bool, state: BatteryReading.State) {
        let strokeColor = color(percent: percent, charging: charging, state: state)
        let bodyPath = sideProfilePath()
        let fillBounds = NSRect(x: 1.3, y: 3.1, width: 24.5, height: 10.2)

        if let percent, state == .active {
            let clamped = max(0, min(100, percent))
            let fillWidth = CGFloat(clamped) / 100 * fillBounds.width
            let fill = NSRect(
                x: fillBounds.minX,
                y: fillBounds.minY,
                width: fillWidth,
                height: fillBounds.height
            )

            NSGraphicsContext.saveGraphicsState()
            bodyPath.addClip()
            NSColor.white.setFill()
            fill.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        strokeColor.setStroke()
        bodyPath.lineWidth = 1.3
        bodyPath.stroke()

        if charging {
            drawPlug(color: strokeColor)
        }
    }

    private static func sideProfilePath() -> NSBezierPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let sourceMinX: CGFloat = 81.755
            let sourceMaxX: CGFloat = 270
            let sourceMaxY: CGFloat = 222.49
            let scaleX: CGFloat = 0.13
            let scaleY: CGFloat = 0.16
            let mirroredX = sourceMinX + sourceMaxX - x
            return NSPoint(
                x: 1.3 + (mirroredX - sourceMinX) * scaleX,
                y: 3.1 + (sourceMaxY - y) * scaleY
            )
        }

        let path = NSBezierPath()
        path.move(to: point(96.9115, 222.2892))
        path.curve(
            to: point(81.755, 200.3352),
            controlPoint1: point(96.4495, 221.8272),
            controlPoint2: point(81.0502, 200.8241)
        )
        path.curve(
            to: point(120.2191, 179.6327),
            controlPoint1: point(91.5, 193.2),
            controlPoint2: point(105.5, 177.8)
        )
        path.curve(
            to: point(187, 159.0362),
            controlPoint1: point(144.0797, 168.937),
            controlPoint2: point(145, 159.0362)
        )
        path.curve(
            to: point(270, 222.2892),
            controlPoint1: point(233.2228, 159.0362),
            controlPoint2: point(270, 187.3555)
        )
        path.curve(
            to: point(96.9115, 222.2892),
            controlPoint1: point(270, 222.49),
            controlPoint2: point(97.0308, 222.4084)
        )
        path.close()
        return path
    }

    private static func drawPlug(color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 11.2, y: 9.5))
        path.line(to: NSPoint(x: 11.2, y: 7.7))
        path.move(to: NSPoint(x: 14.8, y: 9.5))
        path.line(to: NSPoint(x: 14.8, y: 7.7))
        path.move(to: NSPoint(x: 10.3, y: 7.7))
        path.line(to: NSPoint(x: 15.7, y: 7.7))
        path.line(to: NSPoint(x: 15.7, y: 5.9))
        path.line(to: NSPoint(x: 13, y: 5))
        path.line(to: NSPoint(x: 13, y: 3.9))
        path.stroke()
    }

    private static func color(percent: Int?, charging: Bool, state: BatteryReading.State) -> NSColor {
        if charging {
            return .systemBlue
        }
        guard state == .active, let percent else {
            return .secondaryLabelColor
        }
        if percent <= 10 {
            return .systemRed
        }
        if percent <= 20 {
            return .systemOrange
        }
        return .labelColor
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 5
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenuItem = NSMenuItem(title: "Status: Starting", action: nil, keyEquivalent: "")
    private let deviceMenuItem = NSMenuItem(title: "Device: Unknown", action: nil, keyEquivalent: "")
    private let detailMenuItem = NSMenuItem(title: "Detail: Waiting for first refresh", action: nil, keyEquivalent: "")
    private var refreshTimer: Timer?
    private var connectionMonitor: IOHIDManager?
    private var isRefreshing = false
    private var connectionRefreshPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        setStatusImage(StatusIcon.make(percent: nil, charging: false, state: .noDevice))

        if !HIDAccess.hasListenAccess {
            HIDAccess.requestListenAccess()
        }

        startConnectionMonitor()
        refreshNow()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        // Keep battery updates running while the dropdown is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshNow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        guard let manager = connectionMonitor else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        connectionMonitor = nil
    }

    private func startConnectionMonitor() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: WLMouseBatteryReader.vendorID] as CFDictionary)

        let callback: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                delegate.deviceConnectionChanged()
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, callback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, callback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            return // Periodic refresh remains available if monitoring cannot start.
        }
        connectionMonitor = manager
    }

    private func deviceConnectionChanged() {
        // A single USB device can expose several collections. Coalesce events
        // during a query into one fresh read after that query finishes.
        if isRefreshing {
            connectionRefreshPending = true
        } else {
            refreshNow()
        }
    }

    @objc private func refreshNow() {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        detailMenuItem.title = "Detail: Querying WLMouse HID reports"

        DispatchQueue.global(qos: .utility).async {
            let reading = WLMouseBatteryReader().readBattery()
            DispatchQueue.main.async { [weak self] in
                self?.apply(reading)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openInputMonitoringSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security"
        ]

        for value in urls {
            guard let url = URL(string: value) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func configureMenu() {
        statusMenuItem.isEnabled = false
        deviceMenuItem.isEnabled = false
        detailMenuItem.isEnabled = false

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(statusMenuItem)
        menu.addItem(deviceMenuItem)
        menu.addItem(detailMenuItem)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let privacy = NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        privacy.target = self
        menu.addItem(privacy)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit WLMouse Menu Bar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
    }

    private func apply(_ reading: BatteryReading) {
        isRefreshing = false

        switch reading.state {
        case .active:
            let percent = reading.percent ?? 0
            setStatusImage(StatusIcon.make(percent: percent, charging: reading.charging, state: reading.state))
            statusMenuItem.title = reading.charging ? "Status: Charging, \(percent)%" : "Status: \(percent)%"
        case .sleeping:
            setStatusImage(StatusIcon.make(percent: nil, charging: false, state: reading.state))
            statusMenuItem.title = "Status: Sleeping"
        case .noPermission:
            setStatusImage(StatusIcon.make(percent: nil, charging: false, state: reading.state))
            statusMenuItem.title = "Status: Input Monitoring required"
        case .noDevice:
            setStatusImage(StatusIcon.make(percent: nil, charging: false, state: reading.state))
            statusMenuItem.title = "Status: No device"
        case .noResponse:
            setStatusImage(StatusIcon.make(percent: nil, charging: false, state: reading.state))
            statusMenuItem.title = "Status: No battery response"
        case .error:
            setStatusImage(StatusIcon.make(percent: nil, charging: false, state: reading.state))
            statusMenuItem.title = "Status: Error"
        }

        if let deviceName = reading.deviceName {
            let pid = reading.productID.map { String(format: "0x%04X", $0) } ?? "unknown PID"
            deviceMenuItem.title = "Device: \(deviceName) (\(pid))"
        } else {
            deviceMenuItem.title = "Device: None"
        }

        detailMenuItem.title = "Detail: \(reading.detail)"
        statusItem.button?.toolTip = tooltip(for: reading)

        if connectionRefreshPending {
            connectionRefreshPending = false
            refreshNow()
        }
    }

    private func setStatusImage(_ image: NSImage) {
        statusItem.button?.image = image
        statusItem.button?.title = ""
    }

    private func tooltip(for reading: BatteryReading) -> String {
        let device = reading.deviceName ?? "WLMouse"
        switch reading.state {
        case .active:
            let percent = reading.percent.map { "\($0)%" } ?? "unknown"
            let mode = reading.charging ? "charging" : "battery"
            return "\(device): \(percent) \(mode)"
        case .sleeping:
            return "\(device): sleeping"
        case .noPermission:
            return "Input Monitoring permission is required"
        case .noDevice:
            return "No WLMouse device found"
        case .noResponse:
            return "\(device): no battery response"
        case .error:
            return "\(device): \(reading.detail)"
        }
    }
}

private func runOnce() {
    let reading = WLMouseBatteryReader().readBattery()
    switch reading.state {
    case .active:
        let percent = reading.percent.map(String.init) ?? "unknown"
        let charging = reading.charging ? "charging" : "not charging"
        print("Battery: \(percent)% (\(charging))")
    case .sleeping:
        print("Sleeping: receiver replied, but no live battery value")
    case .noPermission:
        print("Input Monitoring permission is required for HID access")
    case .noDevice:
        print("No WLMouse HID devices found")
    case .noResponse:
        print("No battery response: \(reading.detail)")
    case .error:
        print("Error: \(reading.detail)")
    }

    if let deviceName = reading.deviceName {
        let pid = reading.productID.map { String(format: "0x%04X", $0) } ?? "unknown PID"
        print("Device: \(deviceName) (\(pid))")
    }
}

private func runDevices() {
    for line in WLMouseBatteryReader().describeDevices() {
        print(line)
    }
}

private func runProbe() {
    for line in WLMouseBatteryReader().probeDevices() {
        print(line)
    }
}

if CommandLine.arguments.contains("--once") {
    runOnce()
} else if CommandLine.arguments.contains("--devices") {
    runDevices()
} else if CommandLine.arguments.contains("--probe") {
    runProbe()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
