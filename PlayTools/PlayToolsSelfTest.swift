import Foundation
import Security
import UIKit

@_silgen_name("pt_selftest_platform")
private func selfTestPlatform(_ unameMachine: UnsafeMutablePointer<CChar>,
                              _ sysctlMachine: UnsafeMutablePointer<CChar>) -> UInt32

enum PlayToolsSelfTest {
    private enum Group: String, CaseIterable {
        case keychain
        case platform
        case geometry
    }

    private struct Check {
        let name: String
        let status: String
        let detail: String

        init(_ name: String, _ passed: Bool, _ detail: String = "") {
            self.init(name, status: passed ? "pass" : "fail", detail)
        }

        init(_ name: String, status: String, _ detail: String) {
            self.name = name
            self.status = status
            self.detail = detail
        }

        var json: [String: Any] {
            ["name": name, "status": status, "detail": detail]
        }
    }

    static var isRequested: Bool {
        getenv("PLAYTOOLS_SELFTEST").map { strcmp($0, "1") == 0 } == true
    }

    static var isContractFixture: Bool {
        getenv("PLAYTOOLS_SELFTEST_FIXTURE").map { strcmp($0, "1") == 0 } == true &&
            Bundle.main.object(forInfoDictionaryKey: "PlayToolsContractFixture") as? Bool == true
    }

    static func startIfRequested() {
        guard isRequested else { return }
        let environment = ProcessInfo.processInfo.environment
        let requestedGroup = environment["PLAYTOOLS_SELFTEST_GROUP"]
        DispatchQueue.main.async {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            runWhenReady(requestedGroup: requestedGroup, deadline: deadline)
        }
    }

    private static func runWhenReady(requestedGroup: String?, deadline: TimeInterval) {
        let needsWindow = requestedGroup != Group.keychain.rawValue
        let window = needsWindow ? PlayScreen.shared.activePrimaryWindow : nil
        if needsWindow && window == nil && ProcessInfo.processInfo.systemUptime < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                runWhenReady(requestedGroup: requestedGroup, deadline: deadline)
            }
            return
        }
        run(requestedGroup: requestedGroup, window: window)
    }

    private static func run(requestedGroup: String?, window: UIWindow?) {
        var checks: [Check] = []
        var observations: [String: Any] = [:]
        for group in Group.allCases {
            if let requestedGroup = requestedGroup, requestedGroup != group.rawValue {
                checks.append(Check(group.rawValue, status: "skipped", "Group excluded by launch setting"))
                continue
            }
            switch group {
            case .keychain:
                checks += keychainChecks()
            case .platform:
                checks += platformChecks(window: window, observations: &observations)
            case .geometry:
                checks += geometryChecks(window: window, observations: &observations)
            }
        }
        if let requestedGroup = requestedGroup, Group(rawValue: requestedGroup) == nil {
            checks.append(Check("configuration.group", false, "Unknown group: \(requestedGroup)"))
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let passed = !checks.contains { $0.status == "fail" }
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "bundleId": bundleID,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "timestamp": Date().timeIntervalSince1970,
            "group": requestedGroup ?? "all",
            "passed": passed,
            "checks": checks.map(\.json),
            "observations": observations
        ]
        let directory = PlaySettings.shared.settingsUrl.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Automation", isDirectory: true)
        let report = directory.appendingPathComponent("selftest_\(bundleID).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: report, options: .atomic)
            let failures = checks.filter { $0.status == "fail" }.map(\.name).joined(separator: ", ")
            NSLog("[PlayTools-SelfTest] %@ %@ %@", passed ? "PASS" : "FAIL", report.path, failures)
        } catch {
            NSLog("[PlayTools-SelfTest] FAIL could not write %@: %@", report.path, String(describing: error))
        }
    }

    private static func keychainChecks() -> [Check] {
        let service: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.playcover.selftest"
        ]
        let runID = UUID().uuidString
        let queries = (0..<3).map { index in
            service.merging([kSecAttrAccount as String: "\(runID).\(index)"], uniquingKeysWith: { _, new in new })
        }
        // Scope limit checks to this run, including when two tests share a database.
        let runQuery = service.merging([kSecAttrComment as String: runID], uniquingKeysWith: { _, new in new })
        let payloads = (0..<queries.count).map { Data("\(runID).value.\($0)".utf8) }
        var checks: [Check] = []
        for (index, query) in queries.enumerated() {
            var item = query
            item[kSecValueData as String] = payloads[index]
            item[kSecAttrComment as String] = runID
            let status = PlayKeychain.add(item as NSDictionary, result: nil)
            checks.append(Check("keychain.add.\(index)", status == errSecSuccess, "OSStatus \(status)"))
            if index == 0 && status == errSecSuccess {
                let duplicate = PlayKeychain.add(item as NSDictionary, result: nil)
                checks.append(Check("keychain.duplicate", duplicate == errSecDuplicateItem, "OSStatus \(duplicate)"))
            }
        }

        checks += keychainLimitChecks(query: runQuery, payloads: payloads)
        let updated = Data("\(runID).updated".utf8)
        let query = queries[0]
        let updateStatus = PlayKeychain.update(
            query as NSDictionary, attributesToUpdate: [kSecValueData as String: updated]
        )
        let readBack = copyKeychainItem(query, returning: kSecReturnData)
        checks.append(Check("keychain.update", updateStatus == errSecSuccess &&
                            readBack.status == errSecSuccess && readBack.value as? Data == updated,
                            "Update OSStatus \(updateStatus), lookup OSStatus \(readBack.status)"))

        let referenceResult = copyKeychainItem(query, returning: kSecReturnPersistentRef)
        let reference = referenceResult.value as? Data
        checks.append(Check("keychain.persistentRef.opaque", referenceResult.status == errSecSuccess &&
                            reference?.isEmpty == false && reference != updated,
                            "OSStatus \(referenceResult.status)"))
        if let reference = reference, !reference.isEmpty, reference != updated {
            checks += persistentReferenceChecks(reference, scopedTo: query, payload: updated)
        } else {
            checks.append(Check("keychain.persistentRef.lookup", status: "skipped", "No opaque reference available"))
        }
        checks += permanentKeyChecks(tag: Data(runID.utf8))

        for (index, query) in queries.enumerated() {
            let deleted = PlayKeychain.delete(query as NSDictionary)
            let lookup = copyKeychainItem(query, returning: kSecReturnData)
            checks.append(Check("keychain.cleanup.\(index)",
                                (deleted == errSecSuccess || deleted == errSecItemNotFound) &&
                                lookup.status == errSecItemNotFound,
                                "Delete OSStatus \(deleted), lookup OSStatus \(lookup.status)"))
        }
        return checks
    }

    private static func persistentReferenceChecks(_ reference: Data, scopedTo query: [String: Any], payload: Data)
        -> [Check] {
        let refQuery = [kSecValuePersistentRef as String: reference]
        let resolved = copyKeychainItem(refQuery, returning: kSecReturnData)
        let resolvedTarget = resolved.status == errSecSuccess && resolved.value as? Data == payload
        let lookup = Check("keychain.persistentRef.lookup", resolvedTarget, "OSStatus \(resolved.status)")
        guard resolvedTarget else { return [lookup] }

        // Keep every mutating probe scoped to the synthetic service and account.
        var scopedQuery = query
        scopedQuery[kSecValuePersistentRef as String] = reference
        let replacement = payload + Data(".ref".utf8)
        let updateStatus = PlayKeychain.update(
            scopedQuery as NSDictionary, attributesToUpdate: [kSecValueData as String: replacement]
        )
        let changed = copyKeychainItem(refQuery, returning: kSecReturnData)
        let removed = PlayKeychain.delete(scopedQuery as NSDictionary)
        let missing = copyKeychainItem(query, returning: kSecReturnData)
        return [
            lookup,
            Check("keychain.persistentRef.update", updateStatus == errSecSuccess && changed.status == errSecSuccess &&
                  changed.value as? Data == replacement,
                  "Update OSStatus \(updateStatus), lookup OSStatus \(changed.status)"),
            Check("keychain.persistentRef.delete", removed == errSecSuccess && missing.status == errSecItemNotFound,
                  "Delete OSStatus \(removed), lookup OSStatus \(missing.status)")
        ]
    }

    private static func permanentKeyChecks(tag: Data) -> [Check] {
        let parameters: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = PlayKeychain.keyCreateRandomKey(parameters as NSDictionary, error: &error)?.takeRetainedValue()
        else {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
            return [Check("keychain.permanentKey.generate", false, "CFError code \(String(describing: code))")]
        }
        _ = error?.takeRetainedValue()

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag
        ]
        let reference = copyKeychainItem(query, returning: kSecReturnRef)
        let bytes = copyKeychainItem(query, returning: kSecReturnData)
        let externalRepresentation = SecKeyCopyExternalRepresentation(key, nil) as Data?
        let deleted = PlayKeychain.delete(query as NSDictionary)
        if deleted != errSecSuccess, let externalRepresentation = externalRepresentation {
            // A regression could drop the tag. The exact random bytes still identify this test key.
            let fallback: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecValueData as String: externalRepresentation
            ]
            _ = PlayKeychain.delete(fallback as NSDictionary)
        }
        let missing = copyKeychainItem(query, returning: kSecReturnData)
        return [
            Check("keychain.permanentKey.generate", true),
            Check("keychain.permanentKey.reference", reference.status == errSecSuccess &&
                  reference.value.map { CFGetTypeID($0) == SecKeyGetTypeID() } == true,
                  "OSStatus \(reference.status)"),
            Check("keychain.permanentKey.data", bytes.status == errSecSuccess && externalRepresentation != nil &&
                  bytes.value as? Data == externalRepresentation, "OSStatus \(bytes.status)"),
            Check("keychain.permanentKey.cleanup", deleted == errSecSuccess && missing.status == errSecItemNotFound,
                  "Delete OSStatus \(deleted), lookup OSStatus \(missing.status)")
        ]
    }

    private static func keychainLimitChecks(query: [String: Any], payloads: [Data]) -> [Check] {
        let one = copyKeychainItem(query, returning: kSecReturnData)
        let oneValue = (one.value as? Data).map { payloads.contains($0) } ?? false
        let all = copyKeychainItem(query, returning: kSecReturnData, limit: kSecMatchLimitAll)
        let allValues = all.value as? [Data] ?? []
        let two = copyKeychainItem(query, returning: kSecReturnData, limit: NSNumber(value: 2))
        let twoValues = two.value as? [Data] ?? []
        let invalid = copyKeychainItem(query, returning: kSecReturnData, limit: NSNumber(value: 0))
        return [
            Check("keychain.limit.default", one.status == errSecSuccess && oneValue, "OSStatus \(one.status)"),
            Check("keychain.limit.all", all.status == errSecSuccess && Set(allValues) == Set(payloads),
                  "OSStatus \(all.status), array count \(allValues.count)"),
            Check("keychain.limit.numeric", two.status == errSecSuccess && Set(twoValues).count == 2 &&
                  Set(twoValues).isSubset(of: Set(payloads)),
                  "OSStatus \(two.status), array count \(twoValues.count)"),
            Check("keychain.limit.invalid", invalid.status == errSecParam, "OSStatus \(invalid.status)")
        ]
    }

    private static func copyKeychainItem(_ query: [String: Any], returning key: CFString, limit: Any? = nil)
        -> (status: OSStatus, value: CFTypeRef?) {
        var search = query
        search[key as String] = true
        search[kSecMatchLimit as String] = limit
        var value: Unmanaged<CFTypeRef>?
        let status = PlayKeychain.copyMatching(search as NSDictionary, result: &value)
        return (status, value?.takeRetainedValue())
    }

    private static func platformChecks(window: UIWindow?, observations: inout [String: Any]) -> [Check] {
        let settings = PlaySettings.shared
        let device = UIDevice.current
        let process = ProcessInfo.processInfo
        let traits = window?.traitCollection ?? UITraitCollection.current
        var unameMachine = [CChar](repeating: 0, count: 256)
        var sysctlMachine = [CChar](repeating: 0, count: 256)
        let platform = selfTestPlatform(&unameMachine, &sysctlMachine)
        let unameName = String(cString: unameMachine)
        let sysctlName = String(cString: sysctlMachine)
        let layout = settings.layoutIdiom
        let native = settings.useNativePlatform
        let phone = layout == 1 || layout == 3
        #if targetEnvironment(macCatalyst)
        let expectedPlatform: UInt32 = native ? 6 : 2
        #else
        let expectedPlatform: UInt32 = 2
        #endif

        observations["platform"] = [
            "dyld_get_active_platform": platform,
            "layoutIdiom": layout,
            "useNativePlatform": native,
            "isMacCatalystApp": process.isMacCatalystApp,
            "isiOSAppOnMac": process.isiOSAppOnMac,
            "deviceIdiom": device.userInterfaceIdiom.rawValue,
            "traitIdiom": traits.userInterfaceIdiom.rawValue,
            "traitSource": window == nil ? "current" : "window",
            "model": device.model,
            "localizedModel": device.localizedModel,
            "systemName": device.systemName,
            "configuredMachine": settings.deviceModel as String,
            "uname.machine": unameName,
            "hw.machine": sysctlName
        ]
        let matchesProcessIdentity: Bool
        #if targetEnvironment(macCatalyst)
        matchesProcessIdentity = process.isMacCatalystApp == native && !process.isiOSAppOnMac
        #else
        matchesProcessIdentity = native
            ? process.isMacCatalystApp == process.isiOSAppOnMac
            : !process.isMacCatalystApp && !process.isiOSAppOnMac
        #endif
        var checks = [
            Check("platform.dyld", platform == expectedPlatform, "Expected \(expectedPlatform), received \(platform)"),
            Check("platform.processInfo", matchesProcessIdentity),
            Check("platform.machine", sysctlName == settings.deviceModel as String && unameName == sysctlName)
        ]
        if phone || layout == 2 {
            let expected: UIUserInterfaceIdiom = phone ? .phone : .pad
            let model = phone ? "iPhone" : "iPad"
            checks += [
                Check("platform.deviceIdiom", device.userInterfaceIdiom == expected),
                Check("platform.traitIdiom", traits.userInterfaceIdiom == expected),
                Check("platform.model", device.model == model && device.localizedModel == model),
                Check("platform.systemName", device.systemName == "iOS" || (!phone && device.systemName == "iPadOS"))
            ]
        }
        return checks
    }

    static func geometryReport(window: UIWindow, secondary: [(name: String, passed: Bool, detail: String)])
        -> [String: Any] {
        var observations: [String: Any] = [:]
        let checks = geometryChecks(window: window, observations: &observations) +
            secondary.map { Check($0.name, $0.passed, $0.detail) }
        return [
            "action": "selftestGeometry",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "passed": !checks.contains { $0.status == "fail" },
            "checks": checks.map(\.json),
            "observations": observations
        ]
    }

    private static func geometryChecks(window: UIWindow?, observations: inout [String: Any]) -> [Check] {
        let screen = window?.windowScene?.screen ?? UIScreen.main
        let bounds = screen.bounds
        let fixed = screen.fixedCoordinateSpace
        let rotated = screen.coordinateSpace
        var values: [String: Any] = [
            "mode": PlayScreen.shared.currentDisplayMode.name,
            "bounds": rectJSON(bounds),
            "nativeBounds": rectJSON(screen.nativeBounds),
            "scale": screen.scale,
            "nativeScale": screen.nativeScale,
            "coordinateSpace": rectJSON(rotated.bounds),
            "fixedCoordinateSpace": rectJSON(fixed.bounds)
        ]
        defer { observations["geometry"] = values }
        let sample = CGPoint(x: rotated.bounds.midX + rotated.bounds.width / 5, y: rotated.bounds.midY)
        let roundTrip = rotated.convert(rotated.convert(sample, to: fixed), from: fixed)
        let convertedBounds = rotated.convert(rotated.bounds, to: fixed)
        values["coordinateSpaceInFixedSpace"] = rectJSON(convertedBounds)
        let restoredBounds = rotated.convert(convertedBounds, from: fixed)
        var checks = [
            Check("geometry.screenMetrics",
                  validRect(bounds) && validRect(screen.nativeBounds) &&
                  screen.scale.isFinite && screen.scale > 0 && screen.nativeScale.isFinite && screen.nativeScale > 0),
            Check("geometry.coordinateSpace.bounds", validRect(rotated.bounds) && validRect(fixed.bounds)),
            // The virtual app canvas can occupy a subrectangle of the fixed host display.
            Check("geometry.coordinateSpace.rectRoundTrip", equalRect(restoredBounds, rotated.bounds)),
            Check("geometry.coordinateSpace.roundTrip",
                  abs(roundTrip.x - sample.x) <= 0.5 && abs(roundTrip.y - sample.y) <= 0.5)
        ]
        guard let window = window, let scene = window.windowScene else {
            checks.append(Check("geometry.scene", status: "skipped", "No window scene appeared before the timeout"))
            return checks
        }
        if PlaySettings.shared.dynamicWindowMode {
            let nativeSize = CGSize(width: min(bounds.width, bounds.height) * screen.nativeScale,
                                    height: max(bounds.width, bounds.height) * screen.nativeScale)
            checks.append(Check("geometry.nativeBounds",
                                equalRect(screen.nativeBounds, CGRect(origin: .zero, size: nativeSize))))
            checks.append(Check("geometry.screenCanvas",
                                equalRect(bounds, window.bounds) && equalRect(bounds, rotated.bounds)))
        }
        values["windowBounds"] = rectJSON(window.bounds)
        values["sceneBounds"] = rectJSON(scene.coordinateSpace.bounds)
        if let statusBar = scene.statusBarManager {
            let frame = statusBar.statusBarFrame
            values["statusBarFrame"] = rectJSON(frame)
            checks.append(Check("geometry.statusBarFrame",
                                [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
                                    .allSatisfy { $0.isFinite } &&
                                frame.size.width >= 0 && frame.size.height >= 0 &&
                                (frame.isEmpty || (frame.minX >= -1 && frame.minY >= -1 &&
                                                  frame.maxX <= scene.coordinateSpace.bounds.maxX + 1 &&
                                                  frame.maxY <= scene.coordinateSpace.bounds.maxY + 1))))
        }
        switch PlayScreen.shared.currentDisplayMode {
        case .scaled(let logicalSize, _, _):
            let sceneBounds = scene.coordinateSpace.bounds
            let scale = min(sceneBounds.width / logicalSize.width, sceneBounds.height / logicalSize.height)
            let fittedSize = CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)
            let fittedFrame = CGRect(x: sceneBounds.midX - fittedSize.width / 2,
                                     y: sceneBounds.midY - fittedSize.height / 2,
                                     width: fittedSize.width, height: fittedSize.height)
            values["windowFrameInScene"] = rectJSON(window.frame)
            checks.append(Check("geometry.scaled.logicalBounds",
                                equalRect(window.bounds, CGRect(origin: .zero, size: logicalSize))))
            checks.append(Check("geometry.scaled.sceneFit", equalRect(window.frame, fittedFrame)))
        case .adaptive:
            if PlaySettings.shared.dynamicWindowMode {
                checks.append(Check("geometry.adaptive.sceneExtent", equalRect(window.bounds, scene.coordinateSpace.bounds)))
            }
        }
        checks.append(Check("geometry.scene", validRect(scene.coordinateSpace.bounds) && validRect(window.bounds)))
        return checks
    }

    private static func equalRect(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1 &&
            abs(lhs.maxX - rhs.maxX) <= 1 && abs(lhs.maxY - rhs.maxY) <= 1
    }

    private static func rectJSON(_ rect: CGRect) -> [String: Any] {
        let components = ["x": rect.origin.x, "y": rect.origin.y,
                          "width": rect.size.width, "height": rect.size.height]
        return components.mapValues { $0.isFinite ? ($0 as Any) : NSNull() }
    }

    private static func validRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
