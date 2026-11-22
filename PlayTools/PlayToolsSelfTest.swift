import Foundation
#if PLAYTOOLS_FRAMEWORK_PROBES
import AuthenticationServices
import AVFAudio
import CoreMotion
import GameKit
import PassKit
import StoreKit
import UserNotifications
import WebKit
#endif
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
        case entitlements
        case media
        case webkit
        case urls
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
            case .entitlements, .media, .webkit, .urls:
                continue
            }
        }
        if let requestedGroup = requestedGroup, Group(rawValue: requestedGroup) == nil {
            checks.append(Check("configuration.group", false, "Unknown group: \(requestedGroup)"))
        }

        let frameworkGroups: [Group] = [.entitlements, .media, .webkit, .urls]
        let selectedGroups = frameworkGroups.filter { requestedGroup == nil || requestedGroup == $0.rawValue }
        completeFrameworkChecks(selectedGroups[...], explicit: requestedGroup != nil, window: window) { results in
            writeReport(requestedGroup: requestedGroup, checks: checks + results, observations: observations)
        }
    }

    private static func completeFrameworkChecks(_ groups: ArraySlice<Group>, explicit: Bool,
                                                window: UIWindow?, completion: @escaping ([Check]) -> Void) {
        guard let group = groups.first else {
            completion([])
            return
        }
        let next: ([Check]) -> Void = { results in
            completeFrameworkChecks(groups.dropFirst(), explicit: explicit, window: window) {
                completion(results + $0)
            }
        }
        #if PLAYTOOLS_FRAMEWORK_PROBES
        switch group {
        case .entitlements:
            entitlementChecks(completion: next)
        case .media:
            mediaChecks(completion: next)
        case .webkit:
            webKitChecks(window: window, completion: next)
        case .urls:
            urlChecks(completion: next)
        default:
            next([])
        }
        #else
        next([Check(group.rawValue + ".build", status: explicit ? "fail" : "skipped",
                    "Framework probes were excluded from this build")])
        #endif
    }

    private static func writeReport(requestedGroup: String?, checks: [Check], observations: [String: Any]) {
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

#if PLAYTOOLS_FRAMEWORK_PROBES

extension PlayToolsSelfTest {
    // Accept exactly one callback on the main queue. The timeout also covers work
    // that blocks a dedicated worker, while the host owns process-level crash detection.
    private static func boundedChecks(_ name: String, seconds: TimeInterval = 5,
                              cleanup: @escaping () -> Void = {},
                              start: (@escaping ([Check]) -> Void) -> Void,
                              completion: @escaping ([Check]) -> Void) {
        var finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard !finished else { return }
            finished = true
            cleanup()
            completion([Check(name, false, "Timed out after \(seconds) seconds")])
        }
        start { results in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                cleanup()
                completion(results)
            }
        }
    }

    private static func entitlementChecks(completion: @escaping ([Check]) -> Void) {
        let group = DispatchGroup()
        var results = [Check("entitlements.appleID.performRequests", status: "skipped",
                             "Authorization may present sign-in UI")]

        func append(_ name: String, cleanup: @escaping () -> Void = {},
                    start: (@escaping ([Check]) -> Void) -> Void) {
            group.enter()
            boundedChecks(name, cleanup: cleanup, start: start) { checks in
                results.append(contentsOf: checks)
                group.leave()
            }
        }

        append("entitlements.capabilities") { done in
            DispatchQueue.global(qos: .utility).async {
                done([
                    Check("entitlements.passKit.canMakePayments", true,
                          "Returned \(PKPaymentAuthorizationController.canMakePayments())"),
                    Check("entitlements.passKit.isPassLibraryAvailable", true,
                          "Returned \(PKPassLibrary.isPassLibraryAvailable())"),
                    Check("entitlements.storeKit.canMakePayments", true,
                          "Returned \(SKPaymentQueue.canMakePayments())")
                ])
            }
        }
        append("entitlements.notifications.getSettings") { done in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                done([Check("entitlements.notifications.getSettings", true,
                            "UNAuthorizationStatus \(settings.authorizationStatus.rawValue)")])
            }
        }
        if isContractFixture {
            append("entitlements.appleID.getCredentialState") { done in
                ASAuthorizationAppleIDProvider().getCredentialState(forUserID: UUID().uuidString) { state, error in
                    let detail = (error as NSError?).map { "\($0.domain) (\($0.code))" } ?? "no error"
                    done([Check("entitlements.appleID.getCredentialState",
                                error != nil || state == .notFound || state == .revoked,
                                "Credential state \(state.rawValue), \(detail)")])
                }
            }
            let products = StoreKitProductProbe()
            append("entitlements.storeKit.products", cleanup: products.stop, start: products.start)

            let notifications = LocalNotificationProbe()
            append("entitlements.notifications.mutation", cleanup: notifications.stop, start: notifications.start)

            if getenv("PLAYTOOLS_SELFTEST_GAMEKIT").map({ strcmp($0, "1") == 0 }) == true {
                let player = GKLocalPlayer.local
                let previous = player.authenticateHandler
                append("entitlements.gameKit.authenticateHandler", cleanup: { player.authenticateHandler = previous }) {
                    done in
                    player.authenticateHandler = { controller, error in
                        let detail = (error as NSError?).map { "\($0.domain) (\($0.code))" } ?? "no error"
                        done([Check("entitlements.gameKit.authenticateHandler", true,
                                    "Controller provided \(controller != nil), \(detail)")])
                    }
                }
            } else {
                results.append(Check("entitlements.gameKit.authenticateHandler", status: "skipped",
                                     "Explicit signed-out fixture launch required"))
            }
        } else {
            for operation in ["appleID.getCredentialState", "storeKit.products", "gameKit.authenticateHandler",
                              "notifications.requestAuthorization", "notifications.addRequest"] {
                results.append(Check("entitlements." + operation, status: "skipped", "Contract fixture required"))
            }
        }

        group.notify(queue: .main) {
            completion(results.sorted { $0.name < $1.name })
        }
    }
}

extension PlayToolsSelfTest {
    private final class StoreKitProductProbe: NSObject, SKProductsRequestDelegate {
        private var request: SKProductsRequest?
        private var done: (([Check]) -> Void)?
        private let identifier = "io.playcover.selftest." + UUID().uuidString.replacingOccurrences(of: "-", with: "")

        func start(_ done: @escaping ([Check]) -> Void) {
            self.done = done
            let request = SKProductsRequest(productIdentifiers: [identifier])
            self.request = request
            request.delegate = self
            request.start()
        }

        func stop() {
            request?.delegate = nil
            request?.cancel()
            request = nil
            done = nil
        }

        func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
            let invalid = response.invalidProductIdentifiers.contains(identifier)
            let products = response.products.count
            report(products == 0 && invalid, "Products \(products), recognized synthetic ID as invalid \(invalid)")
        }

        func request(_ request: SKRequest, didFailWithError error: Error) {
            let error = error as NSError
            report(true, "\(error.domain) (\(error.code))")
        }

        private func report(_ passed: Bool, _ detail: String) {
            DispatchQueue.main.async { [weak self] in
                self?.done?([Check("entitlements.storeKit.products", passed, detail)])
            }
        }
    }

    private final class LocalNotificationProbe {
        private let center = UNUserNotificationCenter.current()
        private let identifier = "io.playcover.selftest." + UUID().uuidString
        private var active = false

        func start(_ done: @escaping ([Check]) -> Void) {
            active = true
            center.getNotificationSettings { [weak self] settings in
                DispatchQueue.main.async { self?.handleSettings(settings.authorizationStatus, done: done) }
            }
        }

        func stop() {
            active = false
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
        }

        private func handleSettings(_ status: UNAuthorizationStatus, done: @escaping ([Check]) -> Void) {
            guard active else { return }
            let authorization = "entitlements.notifications.requestAuthorization"
            switch status {
            case .authorized, .provisional, .ephemeral, .denied:
                let skipped = Check(authorization, status: "skipped", "Existing authorization state \(status.rawValue)")
                schedule(expectsAcceptance: status != .denied, earlier: [skipped], done: done)
            case .notDetermined:
                guard getenv("PLAYTOOLS_SELFTEST_NOTIFICATION_AUTH").map({ strcmp($0, "1") == 0 }) == true else {
                    done([
                        Check(authorization, status: "skipped", "Explicit fixture provisional authorization required"),
                        Check("entitlements.notifications.addRequest", status: "skipped", "Authorization undetermined")
                    ])
                    return
                }
                center.requestAuthorization(options: [.provisional]) { [weak self] granted, error in
                    let detail = (error as NSError?).map { "\($0.domain) (\($0.code))" } ?? "no error"
                    DispatchQueue.main.async {
                        guard let self = self, self.active else { return }
                        let result = Check(authorization, true, "Granted \(granted), \(detail)")
                        self.schedule(expectsAcceptance: granted, earlier: [result], done: done)
                    }
                }
            @unknown default:
                done([Check("entitlements.notifications.addRequest", status: "skipped",
                            "Unknown authorization state \(status.rawValue)")])
            }
        }

        private func schedule(expectsAcceptance: Bool, earlier: [Check], done: @escaping ([Check]) -> Void) {
            let content = UNMutableNotificationContent()
            content.title = "PlayTools contract fixture"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 86_400, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            center.add(request) { [center, identifier, weak self] error in
                // Also clean up a late completion if the fixture has already timed out.
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                DispatchQueue.main.async {
                    guard let self = self, self.active else { return }
                    let detail = (error as NSError?).map { "\($0.domain) (\($0.code))" } ?? "accepted"
                    let result = Check("entitlements.notifications.addRequest", (error == nil) == expectsAcceptance, detail)
                    center.getPendingNotificationRequests { requests in
                        let removed = !requests.contains { $0.identifier == identifier }
                        done(earlier + [result, Check("entitlements.notifications.cleanup", removed)])
                    }
                }
            }
        }
    }
}
#endif

#if PLAYTOOLS_FRAMEWORK_PROBES

extension PlayToolsSelfTest {
    private static func mediaChecks(completion: @escaping ([Check]) -> Void) {
        let motion = CMMotionManager()
        let motionCheck = Check("media.motion.capabilities", true,
                                "Accelerometer \(motion.isAccelerometerAvailable), gyro \(motion.isGyroAvailable), "
                                + "magnetometer \(motion.isMagnetometerAvailable), device motion "
                                + "\(motion.isDeviceMotionAvailable)")
        guard isContractFixture else {
            completion([
                motionCheck,
                Check("media.pasteboard", status: "skipped", "Fixture required for disposable pasteboard write"),
                Check("media.audio", status: "skipped", "Fixture required for audio category and activation changes")
            ])
            return
        }

        let clipboard = pasteboardCheck()
        boundedChecks("media.audio", seconds: 12) { done in
            DispatchQueue.global(qos: .utility).async {
                done(audioSessionChecks())
            }
        } completion: { audio in
            completion([motionCheck, clipboard] + audio)
        }
    }

    private static func pasteboardCheck() -> Check {
        let name = UIPasteboard.Name(rawValue: "io.playcover.selftest." + UUID().uuidString)
        guard let pasteboard = UIPasteboard(name: name, create: true) else {
            return Check("media.pasteboard", false, "Could not create the disposable named pasteboard")
        }
        defer { UIPasteboard.remove(withName: name) }
        let sample = UUID().uuidString
        pasteboard.string = sample
        return Check("media.pasteboard", pasteboard.string == sample, "Named pasteboard round trip")
    }

    private static func audioSessionChecks() -> [Check] {
        let session = AVAudioSession.sharedInstance()
        let originalCategory = session.category
        let originalMode = session.mode
        let originalPolicy = session.routeSharingPolicy
        let originalOptions = session.categoryOptions

        func probe(_ name: String, operation: () throws -> Void) -> Check {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                try operation()
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                return Check("media.audio." + name, true,
                             "Returned normally (\(String(format: "%.3f", elapsed)) s)")
            } catch let error as NSError {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                return Check("media.audio." + name, false, "\(error.domain) (\(error.code)), "
                             + "\(String(format: "%.3f", elapsed)) s, \(error.localizedDescription)")
            }
        }

        let combinations: [(String, AVAudioSession.Category, AVAudioSession.CategoryOptions)] = [
            ("playAndRecord.defaultToSpeaker", .playAndRecord, .defaultToSpeaker),
            ("playAndRecord.allowBluetoothHFP", .playAndRecord, .allowBluetoothHFP),
            ("playAndRecord.allowBluetoothA2DP", .playAndRecord, .allowBluetoothA2DP),
            ("ambient", .ambient, []),
            ("playback.mixWithOthers", .playback, .mixWithOthers)
        ]
        var checks = combinations.map { name, category, options in
            probe(name) { try session.setCategory(category, mode: .default, options: options) }
        }

        if checks.last?.status == "pass" {
            checks.append(probe("activate") { try session.setActive(true) })
            // A failed activation can partially configure the session. Try to deactivate
            // whenever activation was attempted on this disposable, initially inactive host.
            checks.append(probe("deactivate") { try session.setActive(false, options: .notifyOthersOnDeactivation) })
        } else {
            checks.append(Check("media.audio.activate", status: "skipped", "Mixable playback category setup failed"))
        }
        checks.append(probe("restore") {
            try session.setCategory(originalCategory, mode: originalMode, policy: originalPolicy,
                                    options: originalOptions)
        })
        return checks
    }
}
#endif

#if PLAYTOOLS_FRAMEWORK_PROBES
extension PlayToolsSelfTest {
    private static func webKitChecks(window: UIWindow?, completion: @escaping ([Check]) -> Void) {
        guard isContractFixture else {
            completion([Check("webkit.fixture", status: "skipped", "A marked contract fixture is required")])
            return
        }
        guard let window else {
            completion([Check("webkit.window", false, "No fixture window")])
            return
        }
        let probe = WebKitProbe(window: window)
        boundedChecks("webkit.navigation", seconds: 20, cleanup: probe.stop,
                      start: probe.start, completion: completion)
    }

    private final class WebKitProbe: NSObject, WKNavigationDelegate {
        private enum Variant: String, CaseIterable {
            case recommended
            case explicitDesktop
            case mobileWithSuffix
            case customUserAgent
        }

        private let suffix = "PlayCoverFixture/1.0"
        private let customAgent = "PlayCoverFixture Explicit User Agent"
        private let window: UIWindow
        private var views: [WKWebView] = []
        private var pending: [ObjectIdentifier: Variant] = [:]
        private var results: [Check] = []
        private var completion: (([Check]) -> Void)?

        init(window: UIWindow) {
            self.window = window
        }

        func start(_ completion: @escaping ([Check]) -> Void) {
            self.completion = completion
            for variant in Variant.allCases {
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                if variant == .explicitDesktop {
                    config.defaultWebpagePreferences.preferredContentMode = .desktop
                } else if variant == .mobileWithSuffix {
                    config.defaultWebpagePreferences.preferredContentMode = .mobile
                    config.applicationNameForUserAgent = suffix
                }
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
                if variant == .customUserAgent { view.customUserAgent = customAgent }
                view.navigationDelegate = self
                views.append(view)
                pending[ObjectIdentifier(view)] = variant
                window.addSubview(view)
                view.loadHTMLString("""
                    <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
                    <title>PlayCover WebKit contract</title>
                    """, baseURL: nil)
            }
        }

        func stop() {
            completion = nil
            for view in views {
                view.navigationDelegate = nil
                view.stopLoading()
                view.removeFromSuperview()
            }
            views.removeAll()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let variant = pending[ObjectIdentifier(webView)] else { return }
            webView.evaluateJavaScript("""
                ({userAgent:navigator.userAgent, platform:navigator.platform, touchPoints:navigator.maxTouchPoints,
                  width:window.innerWidth, pixelRatio:window.devicePixelRatio})
                """) { [weak self, weak webView] value, error in
                    guard let self, let webView, let result = value as? [String: Any],
                          let agent = result["userAgent"] as? String,
                          let platform = result["platform"] as? String,
                          let touchPoints = result["touchPoints"] as? Int,
                          let width = result["width"] as? Double,
                          let pixelRatio = result["pixelRatio"] as? Double else {
                        self?.finish(variant, passed: false, detail: error?.localizedDescription ?? "Missing DOM values")
                        return
                    }
                    let mode = webView.configuration.defaultWebpagePreferences.preferredContentMode
                    let settings = PlaySettings.shared
                    let wantsPhone = (settings.layoutIdiom == 1 || settings.layoutIdiom == 3) &&
                        !settings.useNativePlatform
                    var passed = !agent.isEmpty && !platform.isEmpty && touchPoints >= 0 &&
                        width.isFinite && width > 0 && pixelRatio.isFinite && pixelRatio > 0
                    switch variant {
                    case .recommended:
                        if wantsPhone {
                            passed = passed && agent.contains("Mobile") && abs(width - 320) <= 1
                        }
                    case .explicitDesktop:
                        passed = passed && mode == .desktop
                    case .mobileWithSuffix:
                        passed = passed && mode == .mobile && agent.contains(self.suffix) && abs(width - 320) <= 1
                    case .customUserAgent:
                        passed = passed && agent == self.customAgent
                    }
                    let detail = "UA: \(agent) | platform: \(platform) | touch: \(touchPoints) | "
                        + "viewport: \(width) | DPR: \(pixelRatio) | configured mode: \(mode.rawValue)"
                    self.finish(variant, passed: passed, detail: detail)
                }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            if let variant = pending[ObjectIdentifier(webView)] {
                finish(variant, passed: false, detail: error.localizedDescription)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        }

        private func finish(_ variant: Variant, passed: Bool, detail: String) {
            guard let entry = pending.first(where: { $0.value == variant }) else { return }
            pending.removeValue(forKey: entry.key)
            results.append(Check("webkit." + variant.rawValue, passed, detail))
            if pending.isEmpty { completion?(results.sorted { $0.name < $1.name }) }
        }
    }
}
#endif

#if PLAYTOOLS_FRAMEWORK_PROBES
extension PlayToolsSelfTest {
    private static func urlChecks(completion: @escaping ([Check]) -> Void) {
        guard isContractFixture else {
            completion([Check("urls.fixture", status: "skipped", "A marked contract fixture is required")])
            return
        }
        let unknownScheme = "playcover-selftest-" + UUID().uuidString.lowercased()
        guard let unknown = URL(string: unknownScheme + "://fixture"),
              let relative = URL(string: "playcover-selftest-relative"),
              let https = URL(string: "https://example.com"),
              let settings = URL(string: UIApplication.openSettingsURLString),
              let telephone = URL(string: "tel://10086") else {
            completion([Check("urls.configuration", false, "Could not create fixture URLs")])
            return
        }

        let app = UIApplication.shared
        let unhandled = app.canOpenURL(unknown)
        let capabilities = [
            Check("urls.canOpen.https", true, "Returned \(app.canOpenURL(https)); no navigation"),
            Check("urls.canOpen.settings", true, "Returned \(app.canOpenURL(settings)); no navigation"),
            Check("urls.canOpen.telephone", true, "Returned \(app.canOpenURL(telephone)); no call"),
            Check("urls.canOpen.unknown", !unhandled, "Returned \(unhandled)")
        ]
        openUnresolvableURL(unknown, name: "urls.open.unknown") { unknownResults in
            openUnresolvableURL(relative, name: "urls.open.relative") { relativeResults in
                completion(capabilities + unknownResults + relativeResults)
            }
        }
    }

    private static func openUnresolvableURL(_ url: URL, name: String, completion: @escaping ([Check]) -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        boundedChecks(name, seconds: 5) { done in
            UIApplication.shared.open(url, options: [:]) { success in
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                done([Check(name, !success, "Returned \(success) after \(String(format: "%.3f", elapsed)) s")])
            }
        } completion: { results in
            completion(results)
        }
    }
}
#endif
