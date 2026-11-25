import Foundation
import UIKit

let settings = PlaySettings.shared

@objc public final class PlaySettings: NSObject {
    @objc public static let shared = PlaySettings()

    let bundleIdentifier = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
    let settingsUrl: URL
    var settingsData: AppSettingsData

    override init() {
        settingsUrl = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("App Settings")
            .appendingPathComponent("\(bundleIdentifier).plist")
        do {
            let data = try Data(contentsOf: settingsUrl)
            settingsData = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
        } catch {
            settingsData = AppSettingsData()
            print("[PlayTools] PlaySettings decode failed.\n%@")
        }
    }

    lazy var discordActivity = settingsData.discordActivity

    @objc lazy var keymapping = settingsData.keymapping

    lazy var notch = settingsData.notch

    lazy var sensitivity = settingsData.sensitivity / 100

    @objc lazy var bypass = settingsData.bypass

    @objc lazy var windowSizeHeight = CGFloat(settingsData.windowHeight)

    @objc lazy var windowSizeWidth = CGFloat(settingsData.windowWidth)

    @objc lazy var inverseScreenValues = settingsData.inverseScreenValues

    @objc lazy var adaptiveDisplay = settingsData.resolution == 0 ? false : true

    @objc lazy var resolution = settingsData.resolution

    @objc lazy var smartAdaptive = settingsData.resolution == 7

    @objc lazy var dynamicWindowMode = settingsData.resolution == 6 || settingsData.resolution == 7

    @objc lazy var resizableWindow = (settingsData.resolution == 6 || settingsData.resolution == 7)

    @objc lazy var deviceModel: NSString = effectiveDeviceModel as NSString

    private static let appSupportsPhone: Bool = {
        let raw = Bundle.main.infoDictionary?["UIDeviceFamily"]
        let families: [Int]
        if let nums = raw as? [NSNumber] {
            families = nums.map { $0.intValue }
        } else {
            families = raw as? [Int] ?? [1]
        }
        return families.isEmpty || families.contains(1)
    }()

    private var effectiveLayoutIdiom: Int {
        if settingsData.layoutIdiom == 3 && !Self.appSupportsPhone {
            return 0
        }
        return settingsData.layoutIdiom
    }

    private var effectiveDeviceModel: String {
        if effectiveLayoutIdiom == 3 {
            return "iPhone19,4"
        }
        if effectiveLayoutIdiom == 1 && settingsData.iosDeviceModel.hasPrefix("iPad") {
            return "iPhone15,3"
        }
        if effectiveLayoutIdiom == 2 && settingsData.iosDeviceModel.hasPrefix("iPhone") {
            return "iPad13,8"
        }
        if !Self.appSupportsPhone && settingsData.iosDeviceModel.hasPrefix("iPhone") {
            return "iPad13,8"
        }
        return settingsData.iosDeviceModel
    }

    @objc lazy var oemID: NSString = {
        switch effectiveDeviceModel {
        case "iPad6,7":
            return "J98aAP"
        case "iPad8,6":
            return "J320xAP"
        case "iPad13,8":
            return "J522AP"
        case "iPad14,5":
            return "A2436"
        case "iPad16,6":
            return "A2925"
        case "iPhone14,3":
            return "A2645"
        case "iPhone15,3":
            return "A2896"
        case "iPhone16,2":
            return "A2849"
        case "iPhone17,2":
            return "A3084"
        default:
            return "J320xAP"
        }
    }()

    @objc lazy var playChain = settingsData.playChain

    @objc lazy var playChainDebugging = settingsData.playChainDebugging

    @objc lazy var windowFixMethod = settingsData.windowFixMethod

    @objc lazy var customScaler = settingsData.customScaler

    @objc lazy var rootWorkDir = settingsData.rootWorkDir

    @objc lazy var noKMOnInput = settingsData.noKMOnInput

    @objc lazy var enableScrollWheel = settingsData.enableScrollWheel

    @objc lazy var hideTitleBar = settingsData.hideTitleBar

    @objc lazy var floatingWindow = settingsData.floatingWindow

    @objc lazy var displayRotation = settingsData.displayRotation

    @objc lazy var checkMicPermissionSync = settingsData.checkMicPermissionSync

    @objc lazy var limitMotionUpdateFrequency = settingsData.limitMotionUpdateFrequency

    @objc lazy var disableBuiltinMouse = settingsData.disableBuiltinMouse

    @objc lazy var blockSleepSpamming = settingsData.blockSleepSpamming

    @objc lazy var ignoreUnityKeyboardInitializationError = settingsData.ignoreUnityKeyboardInitializationError

    @objc lazy var uiScale = settingsData.uiScale

    @objc lazy var layoutIdiom = effectiveLayoutIdiom

    @objc lazy var sdkShift = settingsData.sdkShift

    @objc lazy var useNativePlatform = settingsData.useNativePlatform
    @objc lazy var cameraRotation = settingsData.cameraRotation
    @objc lazy var cameraFrontMirror = settingsData.cameraFrontMirror
    @objc lazy var cameraBackMirror = settingsData.cameraBackMirror

    @objc lazy var spoofPowerState = settingsData.spoofPowerState
    @objc lazy var blockSplashAds = settingsData.blockSplashAds
    @objc lazy var mockLocationEnabled = settingsData.mockLocationEnabled
    @objc lazy var mockLocationLatitude = settingsData.mockLocationLatitude
    @objc lazy var mockLocationLongitude = settingsData.mockLocationLongitude

    /// Exposes the subset of preferences needed by `AKPlugin` without re-reading or re-decoding the plist.
    @objc public func akPluginSettingsDictionary() -> NSDictionary {
        return [
            "keymapping": settingsData.keymapping,
            "hideTitleBar": settingsData.hideTitleBar,
            "floatingWindow": settingsData.floatingWindow,
            "resolution": settingsData.resolution,
            "resizableAspectRatioType": settingsData.resizableAspectRatioType,
            "resizableAspectRatioWidth": settingsData.resizableAspectRatioWidth,
            "resizableAspectRatioHeight": settingsData.resizableAspectRatioHeight,
            "layoutIdiom": settingsData.layoutIdiom,
            "sdkShift": settingsData.sdkShift
        ]
    }
}

struct AppSettingsData: Codable {
    var keymapping = false
    var sensitivity: Float = 50

    var disableTimeout = false
    var iosDeviceModel = "iPhone19,4"
    var windowWidth = 1920
    var windowHeight = 1080
    var customScaler = 2.0
    var resolution = 7
    var aspectRatio = 1
    var displayRotation = 0
    var notch = false
    var bypass = false
    var discordActivity = DiscordActivity()
    var version = "2.0.0"
    var playChain = false
    var playChainDebugging = false
    var inverseScreenValues = false
    var windowFixMethod = 0
    var rootWorkDir = true
    var noKMOnInput = false
    var enableScrollWheel = true
    var hideTitleBar = false
    var floatingWindow = false
    var checkMicPermissionSync = false
    var limitMotionUpdateFrequency = false
    var disableBuiltinMouse = false
    var resizableAspectRatioType = 0
    var resizableAspectRatioWidth = 0
    var resizableAspectRatioHeight = 0
    var blockSleepSpamming = false
    var ignoreUnityKeyboardInitializationError = false
    var uiScale: Double = 1.0
    var layoutIdiom: Int = 3
    var sdkShift = false
    var useNativePlatform = false
    var cameraRotation = -1
    var cameraFrontMirror = -1
    var cameraBackMirror = -1
    var spoofPowerState = false
    var blockSplashAds = true
    var mockLocationEnabled = false
    var mockLocationLatitude: Double = 39.9042
    var mockLocationLongitude: Double = 116.4074

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keymapping = try container.decodeIfPresent(Bool.self, forKey: .keymapping) ?? false
        sensitivity = try container.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 50
        disableTimeout = try container.decodeIfPresent(Bool.self, forKey: .disableTimeout) ?? false
        iosDeviceModel = try container.decodeIfPresent(String.self, forKey: .iosDeviceModel) ?? "iPhone19,4"
        windowWidth = try container.decodeIfPresent(Int.self, forKey: .windowWidth) ?? 1920
        windowHeight = try container.decodeIfPresent(Int.self, forKey: .windowHeight) ?? 1080
        customScaler = try container.decodeIfPresent(Double.self, forKey: .customScaler) ?? 2.0
        resolution = try container.decodeIfPresent(Int.self, forKey: .resolution) ?? 7
        aspectRatio = try container.decodeIfPresent(Int.self, forKey: .aspectRatio) ?? 1
        displayRotation = try container.decodeIfPresent(Int.self, forKey: .displayRotation) ?? 0
        notch = try container.decodeIfPresent(Bool.self, forKey: .notch) ?? false
        bypass = try container.decodeIfPresent(Bool.self, forKey: .bypass) ?? false
        discordActivity = try container.decodeIfPresent(
            DiscordActivity.self, forKey: .discordActivity) ?? DiscordActivity()
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "2.0.0"
        playChain = try container.decodeIfPresent(Bool.self, forKey: .playChain) ?? false
        playChainDebugging = try container.decodeIfPresent(Bool.self, forKey: .playChainDebugging) ?? false
        inverseScreenValues = try container.decodeIfPresent(Bool.self, forKey: .inverseScreenValues) ?? false
        windowFixMethod = try container.decodeIfPresent(Int.self, forKey: .windowFixMethod) ?? 0
        rootWorkDir = try container.decodeIfPresent(Bool.self, forKey: .rootWorkDir) ?? true
        noKMOnInput = try container.decodeIfPresent(Bool.self, forKey: .noKMOnInput) ?? false
        enableScrollWheel = try container.decodeIfPresent(Bool.self, forKey: .enableScrollWheel) ?? true
        hideTitleBar = try container.decodeIfPresent(Bool.self, forKey: .hideTitleBar) ?? false
        floatingWindow = try container.decodeIfPresent(Bool.self, forKey: .floatingWindow) ?? false
        checkMicPermissionSync = try container.decodeIfPresent(
            Bool.self, forKey: .checkMicPermissionSync) ?? false
        limitMotionUpdateFrequency = try container.decodeIfPresent(
            Bool.self, forKey: .limitMotionUpdateFrequency) ?? false
        disableBuiltinMouse = try container.decodeIfPresent(Bool.self, forKey: .disableBuiltinMouse) ?? false
        resizableAspectRatioType = try container.decodeIfPresent(
            Int.self, forKey: .resizableAspectRatioType) ?? 0
        resizableAspectRatioWidth = try container.decodeIfPresent(
            Int.self, forKey: .resizableAspectRatioWidth) ?? 0
        resizableAspectRatioHeight = try container.decodeIfPresent(
            Int.self, forKey: .resizableAspectRatioHeight) ?? 0
        blockSleepSpamming = try container.decodeIfPresent(Bool.self, forKey: .blockSleepSpamming) ?? false
        ignoreUnityKeyboardInitializationError = try container.decodeIfPresent(
            Bool.self, forKey: .ignoreUnityKeyboardInitializationError) ?? false
        let decodedUIScale = try container.decodeIfPresent(Double.self, forKey: .uiScale) ?? 1.0
        uiScale = decodedUIScale <= 0.0 ? 1.0 : decodedUIScale
        layoutIdiom = try container.decodeIfPresent(Int.self, forKey: .layoutIdiom) ?? 3
        sdkShift = try container.decodeIfPresent(Bool.self, forKey: .sdkShift) ?? false
        useNativePlatform = try container.decodeIfPresent(Bool.self, forKey: .useNativePlatform) ?? false
        cameraRotation = try container.decodeIfPresent(Int.self, forKey: .cameraRotation) ?? -1
        cameraFrontMirror = try container.decodeIfPresent(Int.self, forKey: .cameraFrontMirror) ?? -1
        cameraBackMirror = try container.decodeIfPresent(Int.self, forKey: .cameraBackMirror) ?? -1
        spoofPowerState = try container.decodeIfPresent(Bool.self, forKey: .spoofPowerState) ?? false
        blockSplashAds = try container.decodeIfPresent(Bool.self, forKey: .blockSplashAds) ?? true
        mockLocationEnabled = try container.decodeIfPresent(Bool.self, forKey: .mockLocationEnabled) ?? false
        mockLocationLatitude = try container.decodeIfPresent(Double.self, forKey: .mockLocationLatitude) ?? 39.9042
        mockLocationLongitude = try container.decodeIfPresent(Double.self, forKey: .mockLocationLongitude) ?? 116.4074
    }
}
