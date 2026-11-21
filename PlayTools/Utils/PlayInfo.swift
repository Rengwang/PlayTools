//
//  PlayInformation.swift
//  PlayTools
//

import Foundation
import ObjectiveC.runtime

class PlayInfo: NSObject {
    private static var powerStateHooksInstalled = false

    static var isLauncherInstalled: Bool {
        return AKInterface.shared!
            .urlForApplicationWithBundleIdentifier("io.playcover.PlayCover") != nil
    }

    @objc static var isUnrealEngine: Bool {
        let appFolder = Bundle.main.bundleURL
        let ueFiles: [URL] = [
            appFolder.appendingPathComponent("ue4commandline.txt"),
            appFolder.appendingPathComponent("uecommandline.txt")
        ]

        for ueFile in ueFiles where FileManager.default.fileExists(atPath: ueFile.path) {
            return true
        }
        return false
    }

    @objc static func installPowerStateHooksIfNeeded() {
        guard !powerStateHooksInstalled, PlaySettings.shared.spoofPowerState else {
            return
        }
        powerStateHooksInstalled = true
        let cls: AnyClass = ProcessInfo.self
        if let origThermal = class_getInstanceMethod(cls, #selector(getter: ProcessInfo.thermalState)),
           let hookThermal = class_getInstanceMethod(cls, #selector(ProcessInfo.pt_spoofedThermalState)) {
            method_exchangeImplementations(origThermal, hookThermal)
        }
        if let origLowPower = class_getInstanceMethod(cls, #selector(getter: ProcessInfo.isLowPowerModeEnabled)),
           let hookLowPower = class_getInstanceMethod(cls, #selector(ProcessInfo.pt_spoofedIsLowPowerModeEnabled)) {
            method_exchangeImplementations(origLowPower, hookLowPower)
        }
    }

    @objc static func installLegacyPlatformIdentity() {
        applyPlatformIdentity(isMacCatalystApp: false, isiOSAppOnMac: true)
    }

    @objc static func installPlatformIdentity(useNativePlatform: Bool, isPhoneIdiom: Bool) {
        if isPhoneIdiom {
            applyPlatformIdentity(isMacCatalystApp: false, isiOSAppOnMac: false)
        } else if !useNativePlatform {
            applyPlatformIdentity(isMacCatalystApp: false, isiOSAppOnMac: true)
        }
    }

    private static func applyPlatformIdentity(isMacCatalystApp: Bool, isiOSAppOnMac: Bool) {
        for (name, value) in [("isMacCatalystApp", isMacCatalystApp), ("isiOSAppOnMac", isiOSAppOnMac)] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(ProcessInfo.self, selector) else { continue }
            let getter: @convention(block) (ProcessInfo) -> Bool = { _ in value }
            class_replaceMethod(ProcessInfo.self, selector, imp_implementationWithBlock(getter),
                                method_getTypeEncoding(method))
        }
    }
}

extension ProcessInfo {
    @objc fileprivate func pt_spoofedThermalState() -> ProcessInfo.ThermalState {
        return .nominal
    }
    @objc fileprivate func pt_spoofedIsLowPowerModeEnabled() -> Bool {
        return false
    }
}
