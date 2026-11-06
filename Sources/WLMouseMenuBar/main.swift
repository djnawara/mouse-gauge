// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 David Nawara

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
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, percent: percent, charging: charging, state: state)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(in rect: NSRect, percent: Int?, charging: Bool, state: BatteryReading.State) {
        let strokeColor = color(percent: percent, charging: charging, state: state)
        let markBounds = wlmouseMarkBounds(in: rect)
        let markPath = wlmouseMarkPath(in: rect)

        if let percent, state == .active {
            let clamped = max(0, min(100, percent))
            let fillHeight = CGFloat(clamped) / 100 * markBounds.height
            let fill = NSRect(x: markBounds.minX, y: markBounds.minY, width: markBounds.width, height: fillHeight)

            strokeColor.withAlphaComponent(0.22).setFill()
            markPath.fill()

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: fill).addClip()
            strokeColor.setFill()
            markPath.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            strokeColor.setFill()
            markPath.fill()
        }
    }

    private enum MarkPathCommand {
        case move(CGFloat, CGFloat)
        case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case close
    }

    private static let wlmouseMarkCommands: [MarkPathCommand] = [
        .move(16.27, 14.53),
        .curve(16.27, 14.53, 16.27, 14.53, 16.27, 14.53),
        .curve(16.27, 14.49, 16.27, 14.45, 16.27, 14.41),
        .curve(16.27, 12.70, 16.27, 10.99, 16.27, 9.28),
        .curve(16.27, 8.32, 16.26, 7.36, 16.26, 6.39),
        .curve(16.26, 5.71, 16.26, 5.03, 16.25, 4.35),
        .curve(16.25, 3.93, 16.26, 3.51, 16.25, 3.09),
        .curve(16.25, 2.92, 16.23, 2.74, 16.18, 2.57),
        .curve(15.94, 1.85, 15.50, 1.28, 14.89, 0.85),
        .curve(14.58, 0.63, 14.36, 0.64, 14.05, 0.85),
        .curve(13.67, 1.10, 13.39, 1.44, 13.13, 1.81),
        .curve(12.94, 2.09, 12.77, 2.38, 12.72, 2.72),
        .curve(12.68, 2.97, 12.67, 3.22, 12.67, 3.48),
        .curve(12.67, 8.92, 12.67, 14.37, 12.67, 19.81),
        .curve(12.67, 20.91, 12.68, 22.00, 12.68, 23.10),
        .curve(12.68, 24.01, 12.69, 24.93, 12.68, 25.84),
        .curve(12.68, 26.24, 12.77, 26.59, 12.98, 26.93),
        .curve(13.27, 27.41, 13.63, 27.84, 14.08, 28.19),
        .curve(14.36, 28.41, 14.58, 28.40, 14.87, 28.19),
        .curve(14.90, 28.17, 14.93, 28.14, 14.96, 28.12),
        .curve(15.41, 27.74, 15.78, 27.29, 16.06, 26.76),
        .curve(16.15, 26.59, 16.22, 26.39, 16.25, 26.20),
        .curve(16.29, 25.88, 16.29, 25.55, 16.29, 25.22),
        .curve(16.29, 21.70, 16.29, 18.18, 16.29, 14.65),
        .curve(16.27, 14.62, 16.27, 14.58, 16.27, 14.53),
        .close,
        .move(0.64, 8.64),
        .curve(0.67, 8.47, 0.68, 8.31, 0.72, 8.14),
        .curve(0.76, 7.98, 0.80, 7.82, 0.87, 7.67),
        .curve(1.12, 7.11, 1.44, 6.60, 1.88, 6.16),
        .curve(2.08, 5.96, 2.23, 5.96, 2.43, 6.15),
        .curve(2.88, 6.60, 3.34, 7.05, 3.80, 7.50),
        .curve(4.74, 8.43, 5.67, 9.35, 6.61, 10.28),
        .curve(7.19, 10.86, 7.78, 11.43, 8.30, 12.06),
        .curve(9.04, 12.96, 9.55, 13.97, 9.89, 15.08),
        .curve(10.00, 15.44, 10.12, 15.80, 10.20, 16.17),
        .curve(10.26, 16.42, 10.28, 16.69, 10.28, 16.95),
        .curve(10.29, 18.72, 10.29, 20.50, 10.30, 22.27),
        .curve(10.30, 22.37, 10.31, 22.47, 10.31, 22.57),
        .curve(10.31, 22.74, 10.26, 22.79, 10.10, 22.81),
        .curve(9.65, 22.87, 9.21, 22.84, 8.78, 22.70),
        .curve(8.35, 22.56, 7.94, 22.37, 7.57, 22.10),
        .curve(7.05, 21.72, 6.73, 21.22, 6.60, 20.59),
        .curve(6.53, 20.25, 6.50, 19.90, 6.50, 19.55),
        .curve(6.50, 18.81, 6.51, 18.07, 6.50, 17.34),
        .curve(6.49, 16.78, 6.41, 16.23, 6.15, 15.73),
        .curve(5.94, 15.33, 5.70, 14.96, 5.39, 14.64),
        .curve(4.87, 14.10, 4.33, 13.57, 3.80, 13.04),
        .curve(3.07, 12.31, 2.34, 11.59, 1.61, 10.85),
        .curve(1.46, 10.70, 1.33, 10.55, 1.20, 10.38),
        .curve(0.88, 9.97, 0.69, 9.50, 0.66, 8.97),
        .curve(0.66, 8.95, 0.65, 8.93, 0.64, 8.92),
        .curve(0.64, 8.82, 0.64, 8.73, 0.64, 8.64),
        .close,
        .move(18.62, 21.16),
        .curve(18.62, 20.71, 18.62, 20.26, 18.62, 19.81),
        .curve(18.62, 18.86, 18.62, 17.91, 18.63, 16.96),
        .curve(18.64, 16.37, 18.79, 15.81, 18.97, 15.25),
        .curve(19.22, 14.48, 19.52, 13.73, 19.94, 13.03),
        .curve(20.34, 12.38, 20.82, 11.78, 21.35, 11.25),
        .curve(22.84, 9.75, 24.35, 8.26, 25.85, 6.77),
        .curve(26.06, 6.57, 26.26, 6.36, 26.47, 6.16),
        .curve(26.52, 6.12, 26.57, 6.07, 26.62, 6.04),
        .curve(26.74, 5.97, 26.86, 5.98, 26.96, 6.08),
        .curve(27.56, 6.68, 28.06, 7.36, 28.21, 8.22),
        .curve(28.38, 9.16, 28.14, 10.00, 27.46, 10.68),
        .curve(26.33, 11.82, 25.19, 12.95, 24.05, 14.07),
        .curve(23.62, 14.49, 23.22, 14.93, 22.91, 15.45),
        .curve(22.56, 16.03, 22.42, 16.67, 22.42, 17.34),
        .curve(22.41, 18.18, 22.41, 19.02, 22.40, 19.86),
        .curve(22.39, 20.40, 22.27, 20.92, 22.00, 21.39),
        .curve(21.79, 21.76, 21.47, 22.04, 21.11, 22.26),
        .curve(20.67, 22.53, 20.20, 22.75, 19.68, 22.81),
        .curve(19.38, 22.84, 19.08, 22.83, 18.78, 22.82),
        .curve(18.64, 22.82, 18.59, 22.75, 18.59, 22.59),
        .curve(18.61, 22.11, 18.61, 21.64, 18.62, 21.16),
        .curve(18.62, 21.16, 18.62, 21.16, 18.62, 21.16),
        .close
    ]

    private static func wlmouseMarkBounds(in rect: NSRect) -> NSRect {
        let scale = wlmouseMarkScale(in: rect)
        let width = sourceMarkWidth * scale
        let height = sourceMarkHeight * scale
        return NSRect(
            x: rect.minX + (rect.width - width) / 2,
            y: rect.minY + (rect.height - height) / 2,
            width: width,
            height: height
        )
    }

    private static func wlmouseMarkPath(in rect: NSRect) -> NSBezierPath {
        let bounds = wlmouseMarkBounds(in: rect)
        let scale = wlmouseMarkScale(in: rect)

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            return NSPoint(
                x: bounds.minX + (x - sourceMarkMinX) * scale,
                y: bounds.minY + (sourceMarkMaxY - y) * scale
            )
        }

        let path = NSBezierPath()
        for command in wlmouseMarkCommands {
            switch command {
            case let .move(x, y):
                path.move(to: point(x, y))
            case let .curve(controlX1, controlY1, controlX2, controlY2, x, y):
                path.curve(
                    to: point(x, y),
                    controlPoint1: point(controlX1, controlY1),
                    controlPoint2: point(controlX2, controlY2)
                )
            case .close:
                path.close()
            }
        }

        return path
    }

    private static func wlmouseMarkScale(in rect: NSRect) -> CGFloat {
        min((rect.width - 2) / sourceMarkWidth, (rect.height - 1.2) / sourceMarkHeight)
    }

    private static let sourceMarkMinX: CGFloat = 0.64
    private static let sourceMarkMaxY: CGFloat = 28.41
    private static let sourceMarkWidth: CGFloat = 27.74
    private static let sourceMarkHeight: CGFloat = 27.78

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
