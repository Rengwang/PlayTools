// swiftlint:disable file_length
//
//  ScreenController.swift
//  PlayTools
//
import Foundation
import UIKit

let screen = PlayScreen.shared
let isInvertFixEnabled = PlaySettings.shared.inverseScreenValues && PlaySettings.shared.adaptiveDisplay
let mainScreenWidth = !isInvertFixEnabled
    ? PlaySettings.shared.windowSizeWidth
    : PlaySettings.shared.windowSizeHeight
let mainScreenHeight = !isInvertFixEnabled
    ? PlaySettings.shared.windowSizeHeight
    : PlaySettings.shared.windowSizeWidth

extension CGSize {
    func aspectRatio() -> CGFloat {
        mainScreenWidth > mainScreenHeight
            ? mainScreenWidth / mainScreenHeight
            : mainScreenHeight / mainScreenWidth
    }

    func toAspectRatio() -> CGSize {
        if #available(iOS 16.3, *) {
            return CGSize(width: mainScreenWidth, height: mainScreenHeight)
        } else {
            return CGSize(width: mainScreenHeight, height: mainScreenWidth)
        }
    }

    func toAspectRatioInternal() -> CGSize {
        CGSize(width: mainScreenHeight, height: mainScreenWidth)
    }

    func toAspectRatioDefault() -> CGSize {
        CGSize(width: mainScreenHeight, height: mainScreenWidth)
    }

    func toAspectRatioInternalDefault() -> CGSize {
        CGSize(width: mainScreenWidth, height: mainScreenHeight)
    }
}

extension CGRect {
    func aspectRatio() -> CGFloat {
        mainScreenWidth > mainScreenHeight
            ? mainScreenWidth / mainScreenHeight
            : mainScreenHeight / mainScreenWidth
    }

    func toAspectRatio(_ multiplier: CGFloat = 1) -> CGRect {
        CGRect(x: minX, y: minY, width: mainScreenWidth * multiplier, height: mainScreenHeight * multiplier)
    }

    func toAspectRatioReversed() -> CGRect {
        CGRect(x: minX, y: minY, width: mainScreenHeight, height: mainScreenWidth)
    }

    func toAspectRatioDefault(_ multiplier: CGFloat = 1) -> CGRect {
        CGRect(x: minX, y: minY, width: mainScreenWidth * multiplier, height: mainScreenHeight * multiplier)
    }

    func toAspectRatioReversedDefault() -> CGRect {
        CGRect(x: minX, y: minY, width: mainScreenHeight, height: mainScreenWidth)
    }
}

extension UIScreen {
    static var aspectRatio: CGFloat {
        let count = AKInterface.shared!.screenCount
        if PlaySettings.shared.notch {
            if count == 1 || AKInterface.shared!.isMainScreenEqualToFirst {
                return mainScreenWidth / mainScreenHeight
            }
        }
        let frame = AKInterface.shared!.mainScreenFrame
        return frame.aspectRatio()
    }
}

private struct ScreenAppCapabilities {
    let families: [Int]
    let supportsIPad: Bool
    let supportsDuoAdaptive: Bool
    let requiresFullScreen: Bool
    let hasPortrait: Bool
    let hasLandscape: Bool
    let hasScene: Bool
    let isAdaptive: Bool

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        if let nums = info["UIDeviceFamily"] as? [NSNumber] {
            families = nums.map { $0.intValue }
        } else {
            families = info["UIDeviceFamily"] as? [Int] ?? [1]
        }
        supportsIPad = families.contains(2)
        let forceShift = PlaySettings.shared.dynamicWindowMode && PlaySettings.shared.sdkShift
        let sdk = Self.parseSDKVersion(info["DTSDKName"] as? String)
        supportsDuoAdaptive = forceShift
            || (families.contains(1) && (sdk.major > 27 || (sdk.major == 27 && sdk.minor >= 1)))
        let rawRequiresFullScreen = info["UIRequiresFullScreen"] as? Bool ?? false
        let ignoredFromStr = (info["UIRequiresFullScreenIgnoredStartingWithVersion"] as? String)
            ?? (info["UIRequiresFullScreenIgnoredStartingWithVersion"] as? NSNumber)?.stringValue
        let ignoredFrom = Self.parseSDKVersion(ignoredFromStr)
        let runtimeVer = ProcessInfo.processInfo.operatingSystemVersion
        let ignoresRequiresFullScreen = ignoredFrom.major > 0
            && (runtimeVer.majorVersion > ignoredFrom.major
                || (runtimeVer.majorVersion == ignoredFrom.major && runtimeVer.minorVersion >= ignoredFrom.minor))
        requiresFullScreen = !forceShift && rawRequiresFullScreen && !ignoresRequiresFullScreen
        let ipadOrients = info["UISupportedInterfaceOrientations~ipad"] as? [String] ?? []
        let iphoneOrients = (info["UISupportedInterfaceOrientations~iphone"] as? [String])
            ?? (info["UISupportedInterfaceOrientations"] as? [String]) ?? []
        let orients = (supportsIPad && !ipadOrients.isEmpty) ? ipadOrients : iphoneOrients
        let fallbackOrient = info["UIInterfaceOrientation"] as? String ?? ""
        hasPortrait = orients.contains { $0.contains("Portrait") }
            || (orients.isEmpty && fallbackOrient.contains("Portrait"))
        hasLandscape = orients.contains { $0.contains("Landscape") }
            || (orients.isEmpty && fallbackOrient.contains("Landscape"))
        hasScene = info["UIApplicationSceneManifest"] != nil
        let prefersScaledWindow = info["PlayCoverPrefersScaledWindow"] as? Bool ?? false
        isAdaptive = forceShift
            || (!prefersScaledWindow && (supportsIPad || supportsDuoAdaptive)
                && !requiresFullScreen
                && ((hasPortrait && hasLandscape) || hasScene))
    }

    fileprivate static func parseSDKVersion(_ sdkName: String?) -> (major: Int, minor: Int) {
        guard let sdk = sdkName else { return (0, 0) }
        let digits = sdk.drop { !$0.isNumber }
        let parts = digits.split(separator: ".")
        let major = parts.first.flatMap { Int($0) } ?? 0
        let minor = parts.dropFirst().first.flatMap { Int($0) } ?? 0
        return (major, minor)
    }
}

enum PlayDisplayMode: Equatable {
    case adaptive
    case scaled(logicalSize: CGSize, ratioW: CGFloat, ratioH: CGFloat)

    var name: String {
        switch self {
        case .adaptive: return "adaptive"
        case .scaled: return "scaled"
        }
    }
}

public class PlayScreen: NSObject {
    @objc public static let shared = PlayScreen()

    private let appCapabilities = ScreenAppCapabilities()
    private var displayMode: PlayDisplayMode = .adaptive {
        didSet {
            if case .scaled(let logicalSize, _, _) = displayMode {
                pt_setPlayScreenScaledMode(true)
                updateBoundsSnapshot(CGRect(origin: .zero, size: logicalSize))
            } else {
                pt_setPlayScreenScaledMode(false)
            }
        }
    }
    private var lastAdaptiveBounds: CGRect? {
        didSet {
            if let bounds = lastAdaptiveBounds, bounds != oldValue, displayMode == .adaptive {
                updateBoundsSnapshot(bounds)
            }
        }
    }
    private let boundsSnapshotLock = NSLock()
    private var threadSafeBoundsSnapshot: CGRect?
    private var lastAdaptiveLayoutSize: CGSize = .zero
    private var isResolvingBounds = false
    private var isApplyingScaledLayout = false
    private var didInitialPlaceWindow = false
    private var didTriggerRuntimeFallback = false
    private var relayoutWorkItem: DispatchWorkItem?
    private var lastRelayoutTime: CFAbsoluteTime = 0
    private var fallbackWorkItem: DispatchWorkItem?
    private var automationTimer: DispatchSourceTimer?
    private var didWriteReadyFile = false
    private var originalWindowBackground: UIColor?
    private var savedRootAutoresizingMask: UIView.AutoresizingMask?
    private var scaledViews = NSHashTable<UIView>.weakObjects()
    private var scaledWindows = NSHashTable<UIWindow>.weakObjects()
    private var offscreenWindows = NSHashTable<UIWindow>.weakObjects()
    private var isHostLiveResizing = false
    private var lastDuoLandscapeActive = false
    private weak var cachedPrimaryWindow: UIWindow?
    private var appWindowClassCache: [ObjectIdentifier: Bool] = [:]

    private var isDuoIdentity: Bool {
        PlaySettings.shared.layoutIdiom == 3
            || (PlaySettings.shared.deviceModel as String) == "iPhone19,4"
    }

    private var isForcedPhoneAdaptive: Bool {
        let idiom = PlaySettings.shared.layoutIdiom
        return (idiom == 1 || idiom == 3) && displayMode == .adaptive
    }

    private var shouldAllowRuntimeFallback: Bool {
        PlaySettings.shared.smartAdaptive
            && displayMode == .adaptive
            && !appCapabilities.supportsIPad
            && !(isDuoIdentity && appCapabilities.supportsDuoAdaptive)
            && !PlaySettings.shared.sdkShift
    }

    override init() {
        super.init()
        let mode = Self.initialDisplayMode(capabilities: appCapabilities)
        displayMode = mode
        if case .scaled(let logicalSize, _, _) = mode {
            pt_setPlayScreenScaledMode(true)
            updateBoundsSnapshot(CGRect(origin: .zero, size: logicalSize))
        } else {
            pt_setPlayScreenScaledMode(false)
            updateBoundsSnapshot(initialAdaptiveFallbackBounds())
        }
    }

    func clearTransientCachesOnHide() {
        if Thread.isMainThread {
            cachedPrimaryWindow = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.cachedPrimaryWindow = nil
            }
        }
    }

    private func readBoundsSnapshot() -> CGRect? {
        boundsSnapshotLock.lock()
        defer { boundsSnapshotLock.unlock() }
        return threadSafeBoundsSnapshot
    }

    private func updateBoundsSnapshot(_ rect: CGRect) {
        guard rect.width >= 100, rect.height >= 100 else { return }
        boundsSnapshotLock.lock()
        threadSafeBoundsSnapshot = rect
        boundsSnapshotLock.unlock()
    }

    func initialize() {
        let center = NotificationCenter.default
        let invalidatePrimaryWindow: (Notification) -> Void = { [weak self] _ in
            self?.cachedPrimaryWindow = nil
        }
        for name in [
            UIWindow.didBecomeKeyNotification,
            UIWindow.didBecomeVisibleNotification,
            UIWindow.didBecomeHiddenNotification,
            UIScene.didActivateNotification,
            UIScene.willConnectNotification,
            UIScene.didDisconnectNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main, using: invalidatePrimaryWindow)
        }

        guard PlaySettings.shared.dynamicWindowMode else { return }
        let handleAppearance: (Notification) -> Void = { [weak self] notif in
            self?.handleSceneOrWindowEvent(notif.object)
        }
        for name in [
            UIWindow.didBecomeKeyNotification,
            UIWindow.didBecomeVisibleNotification,
            UIScene.didActivateNotification,
            UIScene.willConnectNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main, using: handleAppearance)
        }
        center.addObserver(
            forName: NSNotification.Name("NSWindowWillStartLiveResizeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleHostWindowLiveResizeStart()
        }
        center.addObserver(
            forName: NSNotification.Name("NSWindowDidResizeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleHostWindowResize(isEndOfLiveResize: false)
        }
        center.addObserver(
            forName: NSNotification.Name("NSWindowDidEndLiveResizeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleHostWindowResize(isEndOfLiveResize: true)
        }
        startAutomationServerIfNeeded()
    }

    @objc public static func frame(_ rect: CGRect) -> CGRect { rect.toAspectRatioReversed() }
    @objc public static func bounds(_ rect: CGRect) -> CGRect { rect.toAspectRatio() }
    @objc public static func nativeBounds(_ rect: CGRect) -> CGRect {
        portraitBounds(rect.toAspectRatio(), scale: reportedNativeScale)
    }
    @objc public static func width(_ size: Int) -> Int { size }
    @objc public static func height(_ size: Int) -> Int { Int(size / Int(UIScreen.aspectRatio)) }
    @objc public static func sizeAspectRatio(_ size: CGSize) -> CGSize { size.toAspectRatio() }
    @objc public static func frameReversedDefault(_ rect: CGRect) -> CGRect { rect.toAspectRatioReversedDefault() }
    @objc public static func frameDefault(_ rect: CGRect) -> CGRect { rect.toAspectRatioDefault() }
    @objc public static func boundsDefault(_ rect: CGRect) -> CGRect { rect.toAspectRatioDefault() }
    @objc public static func nativeBoundsDefault(_ rect: CGRect) -> CGRect {
        portraitBounds(rect.toAspectRatioDefault(), scale: reportedNativeScale)
    }
    @objc public static func sizeAspectRatioDefault(_ size: CGSize) -> CGSize { size.toAspectRatioDefault() }
    @objc public static func frameInternalDefault(_ rect: CGRect) -> CGRect { rect.toAspectRatioDefault() }
    @objc public static func boundsResizable(_ rect: CGRect) -> CGRect { shared.resolveBoundsResizable(rect) }

    @objc public static let reportedNativeScale: CGFloat = {
        let raw = PlaySettings.shared.customScaler
        return raw.isFinite && raw > 0 ? CGFloat(raw) : 2
    }()

    @objc public static func nativeBoundsResizable(_ rect: CGRect) -> CGRect {
        portraitBounds(boundsResizable(rect), scale: reportedNativeScale)
    }

    private static func portraitBounds(_ rect: CGRect, scale: CGFloat = 1) -> CGRect {
        CGRect(x: 0, y: 0, width: min(rect.width, rect.height) * scale,
               height: Swift.max(rect.width, rect.height) * scale)
    }

    @objc public static func onWindowLayoutSubviews(_ window: UIWindow) {
        shared.handleWindowLayoutSubviews(window)
    }

    @objc public static func onViewControllerLayout(_ viewController: UIViewController) {
        shared.handleViewControllerLayout(viewController)
    }

    @objc public static func interceptWindowSetFrame(_ window: UIWindow, frame: CGRect) -> Bool {
        shared.handleWindowSetFrame(window, frame: frame)
    }

    @objc public static func interceptWindowSetBounds(_ window: UIWindow, bounds: CGRect) -> Bool {
        shared.handleWindowSetBounds(window, bounds: bounds)
    }

    @objc public static func onWindowWillSetRootViewController(_ window: UIWindow) {
        shared.ensureWindowScaledBeforeRootVC(window)
    }

    @objc public static func onWindow(_ window: UIWindow, didAddSubview subview: UIView) {
        shared.handleWindowDidAddSubview(window, subview: subview)
    }

    @objc public static func resolvedInterfaceOrientation(
        _ original: UIInterfaceOrientation,
        scene: UIWindowScene?
    ) -> UIInterfaceOrientation {
        guard Thread.isMainThread,
              PlaySettings.shared.dynamicWindowMode,
              shared.displayMode == .adaptive,
              shared.isDuoIdentity else {
            return original
        }
        let targetWindow = scene?.windows.first(where: { shared.isEligiblePrimaryWindow($0) })
            ?? scene?.windows.first(where: { shared.isAppWindow($0) && !$0.isHidden && !shared.isOffscreenWindow($0) })
            ?? shared.activePrimaryWindow
        let refSize: CGSize
        if let win = targetWindow, win.bounds.width > 1, win.bounds.height > 1 {
            refSize = win.bounds.size
        } else if let sceneBounds = scene?.coordinateSpace.bounds,
                  sceneBounds.width > 1, sceneBounds.height > 1 {
            refSize = sceneBounds.size
        } else {
            return original
        }
        return refSize.width > refSize.height ? .landscapeRight : .portrait
    }

    @objc public static func resolvedGeometryInterfaceOrientation(
        _ original: UIInterfaceOrientation,
        coordinateSpaceBounds bounds: CGRect
    ) -> UIInterfaceOrientation {
        guard Thread.isMainThread,
              PlaySettings.shared.dynamicWindowMode,
              shared.displayMode == .adaptive,
              shared.isDuoIdentity else {
            return original
        }
        if bounds.width > 1, bounds.height > 1 {
            return bounds.width > bounds.height ? .landscapeRight : .portrait
        }
        return resolvedInterfaceOrientation(original, scene: nil)
    }

    @objc public static func resolvedFixedCoordinateSpaceBounds(
        _ original: CGRect,
        screen: UIScreen?
    ) -> CGRect {
        guard Thread.isMainThread,
              PlaySettings.shared.dynamicWindowMode,
              shared.displayMode == .adaptive,
              shared.isDuoIdentity,
              let win = shared.activePrimaryWindow,
              win.bounds.width > 1,
              win.bounds.height > 1,
              let scene = win.windowScene else {
            return original
        }
        if let screen = screen, scene.screen !== screen {
            return original
        }
        let activeAppScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                ($0.activationState == .foregroundActive || $0.activationState == .foregroundInactive)
                    && $0.windows.contains(where: { shared.isEligiblePrimaryWindow($0) })
            }
        guard activeAppScenes.count <= 1 else {
            return original
        }
        let sceneBounds = scene.coordinateSpace.bounds
        guard sceneBounds.width > 1, sceneBounds.height > 1,
              abs(win.bounds.width - sceneBounds.width) <= 2,
              abs(win.bounds.height - sceneBounds.height) <= 2 else {
            return original
        }
        return CGRect(origin: .zero, size: win.bounds.size)
    }

    @objc public static func resolvedMainBundleInfoValue(
        _ original: Any?,
        forKey key: String
    ) -> Any? {
        guard PlaySettings.shared.dynamicWindowMode,
              PlaySettings.shared.sdkShift else {
            return original
        }
        switch key {
        case "DTSDKName":
            let sdk = ScreenAppCapabilities.parseSDKVersion(original as? String)
            if sdk.major < 27 || (sdk.major == 27 && sdk.minor < 1) {
                return "iphoneos27.2"
            }
            return original
        case "UIRequiresFullScreen":
            return NSNumber(value: false)
        case "UIRequiresFullScreenIgnoredStartingWithVersion":
            return original ?? "27.0"
        default:
            return original
        }
    }

    @objc public static func resolvedMainBundleInfoDictionary(
        _ original: [AnyHashable: Any]?
    ) -> [AnyHashable: Any]? {
        guard PlaySettings.shared.dynamicWindowMode,
              PlaySettings.shared.sdkShift,
              var dict = original else {
            return original
        }
        let sdk = ScreenAppCapabilities.parseSDKVersion(dict["DTSDKName"] as? String)
        if sdk.major < 27 || (sdk.major == 27 && sdk.minor < 1) {
            dict["DTSDKName"] = "iphoneos27.2"
        }
        dict["UIRequiresFullScreen"] = NSNumber(value: false)
        if dict["UIRequiresFullScreenIgnoredStartingWithVersion"] == nil {
            dict["UIRequiresFullScreenIgnoredStartingWithVersion"] = "27.0"
        }
        return dict
    }

    var fullscreen: Bool { AKInterface.shared?.isFullscreen ?? false }
    var resizable: Bool { PlaySettings.shared.resizableWindow }
    @objc public var screenRect: CGRect { UIScreen.main.bounds }
    var width: CGFloat { screenRect.width }
    var height: CGFloat { screenRect.height }
    var max: CGFloat { Swift.max(width, height) }
    var percent: CGFloat { max / 100.0 }

    var activePrimaryWindow: UIWindow? {
        if Thread.isMainThread,
           let cached = cachedPrimaryWindow,
           !cached.isHidden,
           cached.alpha > 0.01,
           cached.windowScene != nil,
           !offscreenWindows.contains(cached),
           cached.bounds.width > 1,
           cached.bounds.height > 1 {
            return cached
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .sorted { sceneRank($0.activationState) < sceneRank($1.activationState) }
        var candidates: [UIWindow] = []
        for scene in scenes {
            for win in scene.windows where isEligiblePrimaryWindow(win) {
                candidates.append(win)
            }
        }
        let resolved = candidates.max { windowScore($0) < windowScore($1) }
        if Thread.isMainThread {
            cachedPrimaryWindow = resolved
        }
        return resolved
    }

    var primaryWindowBounds: CGRect? {
        activePrimaryWindow?.bounds
    }

    var currentDisplayMode: PlayDisplayMode { displayMode }

    func windowPoint(forNormalizedContentX nx: CGFloat, y ny: CGFloat) -> CGPoint? {
        guard let win = activePrimaryWindow else {
            return CGPoint(x: nx * screenRect.width, y: ny * screenRect.height)
        }
        if case .scaled = displayMode, let space = win.windowScene?.coordinateSpace {
            let sceneBounds = space.bounds
            guard sceneBounds.width > 1, sceneBounds.height > 1 else { return nil }
            let scenePoint = CGPoint(x: sceneBounds.minX + nx * sceneBounds.width,
                                     y: sceneBounds.minY + ny * sceneBounds.height)
            let windowPoint = win.convert(scenePoint, from: space)
            return win.bounds.contains(windowPoint) ? windowPoint : nil
        }
        return CGPoint(x: nx * win.bounds.width, y: ny * win.bounds.height)
    }

    func resolveTouchTarget(
        forNormalizedContentX normalizedX: CGFloat,
        y normalizedY: CGFloat
    ) -> (window: UIWindow, point: CGPoint, hitView: UIView)? {
        guard let primary = activePrimaryWindow,
              primary.bounds.width >= 1,
              primary.bounds.height >= 1 else {
            return nil
        }
        let primaryPoint: CGPoint
        if PlaySettings.shared.dynamicWindowMode {
            guard let mapped = windowPoint(forNormalizedContentX: normalizedX, y: normalizedY) else {
                return nil
            }
            primaryPoint = mapped
        } else if let space = primary.windowScene?.coordinateSpace,
                  space.bounds.width > 1,
                  space.bounds.height > 1 {
            let scenePoint = CGPoint(
                x: space.bounds.minX + normalizedX * space.bounds.width,
                y: space.bounds.minY + normalizedY * space.bounds.height
            )
            let converted = primary.convert(scenePoint, from: space)
            guard primary.bounds.contains(converted) else { return nil }
            primaryPoint = converted
        } else {
            primaryPoint = CGPoint(
                x: normalizedX * primary.bounds.width,
                y: normalizedY * primary.bounds.height
            )
        }
        return resolveHitTarget(for: primaryPoint, primary: primary)
    }

    var keyWindow: UIWindow? { activePrimaryWindow }
    var windowScene: UIWindowScene? { activePrimaryWindow?.windowScene }
    var window: UIWindow? { activePrimaryWindow }
    var nsWindow: NSObject? { activePrimaryWindow?.nsWindow }

    func switchDock(_ visible: Bool) {
        AKInterface.shared?.setMenuBarVisible(visible)
    }
}

private extension PlayScreen {
    static func initialDisplayMode(capabilities: ScreenAppCapabilities) -> PlayDisplayMode {
        guard PlaySettings.shared.smartAdaptive else {
            return .adaptive
        }
        if capabilities.isAdaptive {
            return .adaptive
        }
        let data = PlaySettings.shared.settingsData
        if data.resizableAspectRatioType != 0,
           data.resizableAspectRatioWidth > 0,
           data.resizableAspectRatioHeight > 0 {
            let ratioW = CGFloat(data.resizableAspectRatioWidth)
            let ratioH = CGFloat(data.resizableAspectRatioHeight)
            return .scaled(
                logicalSize: logicalSizeForRatio(w: data.resizableAspectRatioWidth, h: data.resizableAspectRatioHeight),
                ratioW: ratioW,
                ratioH: ratioH
            )
        }
        if capabilities.hasLandscape && !capabilities.hasPortrait {
            return .scaled(logicalSize: CGSize(width: 1280, height: 720), ratioW: 16, ratioH: 9)
        }
        if capabilities.supportsIPad && !capabilities.families.contains(1) {
            return .scaled(logicalSize: CGSize(width: 768, height: 1024), ratioW: 3, ratioH: 4)
        }
        return .scaled(logicalSize: CGSize(width: 414, height: 736), ratioW: 9, ratioH: 16)
    }

    static func logicalSizeForRatio(w: Int, h: Int) -> CGSize {
        if w == 9 && h == 16 { return CGSize(width: 414, height: 736) }
        if w == 16 && h == 9 { return CGSize(width: 1280, height: 720) }
        if w == 3 && h == 4 { return CGSize(width: 768, height: 1024) }
        if w == 4 && h == 3 { return CGSize(width: 1024, height: 768) }
        let ratio = CGFloat(w) / CGFloat(h)
        if w >= h {
            return CGSize(width: round(720 * ratio), height: 720)
        }
        return CGSize(width: 414, height: round(414 / ratio))
    }

    static func minSizeForRatio(ratioW: CGFloat, ratioH: CGFloat) -> CGSize {
        let wInt = Int(round(ratioW))
        let hInt = Int(round(ratioH))
        if wInt == 9 && hInt == 16 { return CGSize(width: 270, height: 480) }
        if wInt == 16 && hInt == 9 { return CGSize(width: 480, height: 270) }
        if wInt == 3 && hInt == 4 { return CGSize(width: 360, height: 480) }
        if wInt == 4 && hInt == 3 { return CGSize(width: 480, height: 360) }
        if ratioW >= ratioH {
            return CGSize(width: round(270 * ratioW / ratioH), height: 270)
        }
        return CGSize(width: 270, height: round(270 * ratioH / ratioW))
    }

    func resolveBoundsResizable(_ rect: CGRect) -> CGRect {
        if !Thread.isMainThread {
            if let snapshot = readBoundsSnapshot() {
                return snapshot
            }
            if rect.width >= 100, rect.height >= 100 {
                return CGRect(origin: .zero, size: rect.size)
            }
            return initialAdaptiveFallbackBounds()
        }

        if case .scaled(let logicalSize, _, _) = displayMode {
            return CGRect(origin: .zero, size: logicalSize)
        }
        let fallback = lastAdaptiveBounds ?? initialAdaptiveFallbackBounds()
        guard !isResolvingBounds else { return fallback }
        isResolvingBounds = true
        defer { isResolvingBounds = false }

        if let win = activePrimaryWindow, win.bounds.width >= 100, win.bounds.height >= 100 {
            let resolved = CGRect(origin: .zero, size: win.bounds.size)
            if lastAdaptiveBounds != resolved {
                lastAdaptiveBounds = resolved
            }
            return resolved
        }
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.session.role == .windowApplication }) {
            let sBounds = scene.coordinateSpace.bounds
            if sBounds.width >= 100, sBounds.height >= 100 {
                let resolved = CGRect(origin: .zero, size: sBounds.size)
                if lastAdaptiveBounds != resolved {
                    lastAdaptiveBounds = resolved
                }
                return resolved
            }
        }
        if let content = AKInterface.shared?.contentLayoutRect,
           content.width >= 100, content.height >= 100 {
            let resolved = CGRect(origin: .zero, size: content.size)
            if lastAdaptiveBounds != resolved {
                lastAdaptiveBounds = resolved
            }
            return resolved
        }
        return fallback
    }

    private func initialAdaptiveFallbackBounds() -> CGRect {
        let cfg = PlaySettings.shared.settingsData
        if cfg.windowWidth >= 100 && cfg.windowWidth <= 1400 &&
           cfg.windowHeight >= 100 && cfg.windowHeight <= 1200 {
            return CGRect(x: 0, y: 0, width: CGFloat(cfg.windowWidth), height: CGFloat(cfg.windowHeight))
        }
        return CGRect(x: 0, y: 0, width: 900, height: 760)
    }

    func sceneRank(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive: return 0
        case .foregroundInactive: return 1
        case .background: return 2
        default: return 3
        }
    }

    func isAppWindow(_ window: UIWindow) -> Bool {
        if window === EditorController.shared.editorWindow {
            return false
        }
        let winClass: AnyClass = type(of: window)
        let key = ObjectIdentifier(winClass)
        if Thread.isMainThread, let cached = appWindowClassCache[key] {
            return cached
        }
        let cls = NSStringFromClass(winClass)
        let allowed = !(cls.contains("Keyboard") || cls.contains("TextEffects") || cls.contains("Snapshot")
            || cls.contains("Menu") || cls.contains("StatusBar") || cls.hasPrefix("_UI"))
        if Thread.isMainThread {
            appWindowClassCache[key] = allowed
        }
        return allowed
    }

    func viewportReferenceBounds(for window: UIWindow) -> CGRect {
        var ref = CGRect.null
        if let s = window.windowScene?.coordinateSpace.bounds, s.width > 1, s.height > 1 {
            ref = ref.union(s)
        }
        if case .scaled(let logicalSize, _, _) = displayMode,
           logicalSize.width > 1, logicalSize.height > 1 {
            ref = ref.union(CGRect(origin: .zero, size: logicalSize))
        }
        if ref.isNull {
            if let last = lastAdaptiveBounds, last.width > 1, last.height > 1 {
                return last
            }
            let screenBounds = UIScreen.main.bounds
            if screenBounds.width > 1, screenBounds.height > 1 {
                return screenBounds
            }
            return initialAdaptiveFallbackBounds()
        }
        return ref
    }

    func isOffscreenFrame(_ frame: CGRect, for window: UIWindow) -> Bool {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              !frame.isNull, !frame.isInfinite else {
            return false
        }
        guard frame.width > 1, frame.height > 1 else {
            return false
        }
        let ref = viewportReferenceBounds(for: window)
        guard !ref.isNull, ref.width > 1, ref.height > 1 else {
            return false
        }
        return !frame.intersects(ref)
    }

    func isOffscreenWindow(_ window: UIWindow) -> Bool {
        offscreenWindows.contains(window) || isOffscreenFrame(window.frame, for: window)
    }

    func isEligiblePrimaryWindow(_ window: UIWindow) -> Bool {
        !window.isHidden && window.alpha > 0.01 && isAppWindow(window) && !isOffscreenWindow(window)
    }

    func isUnfoldedDuoLandscape(for window: UIWindow) -> Bool {
        guard PlaySettings.shared.dynamicWindowMode,
              displayMode == .adaptive,
              isDuoIdentity else {
            return false
        }
        let width = window.bounds.width > 1
            ? window.bounds.width
            : (window.windowScene?.coordinateSpace.bounds.width ?? 0)
        let height = window.bounds.height > 1
            ? window.bounds.height
            : (window.windowScene?.coordinateSpace.bounds.height ?? 0)
        guard width > height, width >= 600 else { return false }
        return isEligiblePrimaryWindow(window)
    }

    func windowScore(_ window: UIWindow) -> Double {
        var score: Double = 0
        if window.rootViewController != nil { score += 10_000 }
        if window.isKeyWindow { score += 1_000 }
        if window.windowLevel == .normal { score += 500 }
        score += Double(window.bounds.width * window.bounds.height) / 1_000_000.0
        return score
    }

    func applySceneSizeRestrictions(for scene: UIWindowScene?) {
        guard let restrictions = scene?.sizeRestrictions else { return }
        let targetMin: CGSize
        let targetMax = CGSize(width: 8000, height: 8000)
        switch displayMode {
        case .adaptive:
            targetMin = CGSize(width: 360, height: 540)
        case .scaled(_, let ratioW, let ratioH):
            targetMin = Self.minSizeForRatio(ratioW: ratioW, ratioH: ratioH)
        }
        if abs(restrictions.minimumSize.width - targetMin.width) > 0.5
            || abs(restrictions.minimumSize.height - targetMin.height) > 0.5 {
            restrictions.minimumSize = targetMin
        }
        if abs(restrictions.maximumSize.width - targetMax.width) > 0.5
            || abs(restrictions.maximumSize.height - targetMax.height) > 0.5 {
            restrictions.maximumSize = targetMax
        }
    }

    func handleSceneOrWindowEvent(_ object: Any?) {
        cachedPrimaryWindow = nil
        if let scene = object as? UIWindowScene {
            applySceneSizeRestrictions(for: scene)
        } else if let win = object as? UIWindow {
            applySceneSizeRestrictions(for: win.windowScene)
            handleWindowLayoutSubviews(win)
        } else {
            applySceneSizeRestrictions(for: activePrimaryWindow?.windowScene)
        }
        ensureInitialPlacementAndFallback()
    }

    func ensureInitialPlacementAndFallback() {
        if !didInitialPlaceWindow, activePrimaryWindow != nil {
            didInitialPlaceWindow = true
            let targetEnv = ProcessInfo.processInfo.environment["PLAYCOVER_TARGET_SCREEN"] ?? ""
            if !targetEnv.isEmpty {
                AKInterface.shared?.placeWindowOnTargetScreenIfNeeded()
            }
            if PlaySettings.shared.smartAdaptive && displayMode == .adaptive {
                let minW: CGFloat = (PlaySettings.shared.layoutIdiom == 1 || PlaySettings.shared.layoutIdiom == 3) ? 320 : 360
                let minH: CGFloat = (PlaySettings.shared.layoutIdiom == 1 || PlaySettings.shared.layoutIdiom == 3) ? 520 : 540
                AKInterface.shared?.clearWindowAspectLock(minWidth: minW, minHeight: minH)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.displayMode == .adaptive else { return }
                    AKInterface.shared?.clearWindowAspectLock(minWidth: minW, minHeight: minH)
                }
            }
            if shouldAllowRuntimeFallback {
                scheduleRuntimeFallbackCheck(delay: 0.8)
            }
        }
    }

    func handleHostWindowLiveResizeStart() {
        isHostLiveResizing = true
        if isForcedPhoneAdaptive {
            relayoutWorkItem?.cancel()
            relayoutWorkItem = nil
            fallbackWorkItem?.cancel()
            fallbackWorkItem = nil
        }
    }

    func handleHostWindowResize(isEndOfLiveResize: Bool) {
        if isEndOfLiveResize {
            isHostLiveResizing = false
        }
        guard let win = activePrimaryWindow else { return }
        switch displayMode {
        case .adaptive:
            lastAdaptiveBounds = CGRect(origin: .zero, size: win.bounds.size)
            if isForcedPhoneAdaptive {
                if isEndOfLiveResize {
                    scheduleFinalAdaptiveLayoutIfNeeded(for: win, delay: 0.0)
                } else if !isHostLiveResizing {
                    scheduleFinalAdaptiveLayoutIfNeeded(for: win, delay: 0.08)
                } else {
                    relayoutWorkItem?.cancel()
                    relayoutWorkItem = nil
                }
                return
            }
            scheduleAdaptiveRelayout(for: win)
        case .scaled(let logicalSize, _, _):
            applyScaledCanvasToScene(containing: win, logicalSize: logicalSize)
            DispatchQueue.main.async { [weak self, weak win] in
                guard let self = self, let win = win,
                      case .scaled(let currentLogical, _, _) = self.displayMode else { return }
                self.applyScaledCanvasToScene(containing: win, logicalSize: currentLogical)
            }
        }
    }

    func handleWindowSetFrame(_ window: UIWindow, frame: CGRect) -> Bool {
        guard PlaySettings.shared.dynamicWindowMode,
              !isApplyingScaledLayout,
              isAppWindow(window) else {
            return false
        }
        if isOffscreenFrame(frame, for: window) {
            offscreenWindows.add(window)
            if scaledWindows.contains(window) {
                scaledWindows.remove(window)
                if window.transform != .identity {
                    isApplyingScaledLayout = true
                    window.transform = .identity
                    isApplyingScaledLayout = false
                }
            }
            if cachedPrimaryWindow === window {
                cachedPrimaryWindow = nil
            }
            return false
        }
        if frame.width > 1, frame.height > 1 {
            offscreenWindows.remove(window)
        }
        guard case .scaled(let logicalSize, _, _) = displayMode else {
            return false
        }
        let container = resolveContainerBounds(for: window, candidate: frame, logicalSize: logicalSize)
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
        return true
    }

    func handleWindowSetBounds(_ window: UIWindow, bounds: CGRect) -> Bool {
        guard PlaySettings.shared.dynamicWindowMode,
              !isApplyingScaledLayout,
              case .scaled(let logicalSize, _, _) = displayMode,
              isAppWindow(window),
              !isOffscreenWindow(window) else {
            return false
        }
        let container: CGRect
        if let s = window.windowScene?.coordinateSpace.bounds, s.width > 1, s.height > 1 {
            container = s
        } else if bounds.width > 1, bounds.height > 1 {
            container = CGRect(origin: .zero, size: bounds.size)
        } else {
            container = CGRect(origin: .zero, size: logicalSize)
        }
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
        return true
    }

    func ensureWindowScaledBeforeRootVC(_ window: UIWindow) {
        guard PlaySettings.shared.dynamicWindowMode,
              !isApplyingScaledLayout,
              case .scaled(let logicalSize, _, _) = displayMode,
              isAppWindow(window),
              !isOffscreenWindow(window) else {
            return
        }
        let container = window.windowScene?.coordinateSpace.bounds
            ?? (window.bounds.width > 1 && window.bounds.height > 1
                ? window.bounds : CGRect(origin: .zero, size: logicalSize))
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
    }

    func handleWindowDidAddSubview(_ window: UIWindow, subview: UIView) {
        guard PlaySettings.shared.dynamicWindowMode,
              case .scaled(let logicalSize, _, _) = displayMode,
              isAppWindow(window),
              !isOffscreenWindow(window),
              subview.superview === window else {
            return
        }
        let container = window.windowScene?.coordinateSpace.bounds
            ?? (window.bounds.width > 1 && window.bounds.height > 1
                ? window.bounds : CGRect(origin: .zero, size: logicalSize))
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
        clampDirectWindowSubviewIfNeeded(subview, in: window)
    }

    func handleWindowLayoutSubviews(_ window: UIWindow) {
        guard PlaySettings.shared.dynamicWindowMode, isEligiblePrimaryWindow(window) else { return }
        applySceneSizeRestrictions(for: window.windowScene)
        ensureInitialPlacementAndFallback()

        switch displayMode {
        case .scaled(let logicalSize, _, _):
            applyScaledCanvas(to: window, logicalSize: logicalSize)
        case .adaptive:
            resetScaledTransformsIfNeeded(in: window)
            if window === activePrimaryWindow {
                let nowDuoLandscape = isUnfoldedDuoLandscape(for: window)
                if nowDuoLandscape != lastDuoLandscapeActive {
                    lastDuoLandscapeActive = nowDuoLandscape
                    window.setNeedsLayout()
                    if !isHostLiveResizing {
                        scheduleAdaptiveRelayout(for: window)
                    }
                }
                if abs(window.bounds.width - lastAdaptiveLayoutSize.width) > 0.5
                    || abs(window.bounds.height - lastAdaptiveLayoutSize.height) > 0.5 {
                    lastAdaptiveLayoutSize = window.bounds.size
                    lastAdaptiveBounds = CGRect(origin: .zero, size: window.bounds.size)
                    if isForcedPhoneAdaptive {
                        // Let UIKit drive intermediate layout frames during live drag;
                        // coalesce one lightweight pass after resizing settles.
                        if !isHostLiveResizing {
                            scheduleFinalAdaptiveLayoutIfNeeded(for: window, delay: 0.08)
                        }
                        return
                    }
                    scheduleAdaptiveRelayout(for: window)
                }
            }
        }
    }

    func handleViewControllerLayout(_ viewController: UIViewController) {
        guard PlaySettings.shared.dynamicWindowMode,
              case .scaled(let logicalSize, _, _) = displayMode,
              let win = viewController.viewIfLoaded?.window,
              isEligiblePrimaryWindow(win),
              viewController === win.rootViewController || viewController.viewIfLoaded?.superview === win else {
            return
        }
        applyScaledCanvas(to: win, logicalSize: logicalSize)
    }
}

private extension PlayScreen {
    func resetScaledTransformsIfNeeded(in window: UIWindow) {
        guard scaledWindows.count > 0 || scaledViews.count > 0 || originalWindowBackground != nil else {
            return
        }
        let didTrackScaledViews = scaledViews.allObjects.contains {
            $0.window === window || $0.superview === window
        }
        guard scaledWindows.contains(window)
                || didTrackScaledViews
                || originalWindowBackground != nil else {
            return
        }
        defer { scaledWindows.remove(window) }

        let sceneBounds = window.windowScene?.coordinateSpace.bounds
        let needsWindowReset = window.transform != .identity || (sceneBounds.map {
            $0.width > 1 && $0.height > 1 && (
                abs(window.frame.width - $0.width) > 0.5
                || abs(window.frame.height - $0.height) > 0.5
            )
        } ?? false)
        if needsWindowReset {
            isApplyingScaledLayout = true
            if window.transform != .identity { window.transform = .identity }
            if let s = sceneBounds, s.width > 1, s.height > 1 {
                window.frame = s
            }
            isApplyingScaledLayout = false
            window.setNeedsLayout()
        }
        resetChildViewTransformsIfNeeded(in: window)
        if let savedBg = originalWindowBackground {
            window.backgroundColor = savedBg
            originalWindowBackground = nil
        }
    }

    func resetChildViewTransformsIfNeeded(in window: UIWindow) {
        let rootView = window.rootViewController?.view
        for view in scaledViews.allObjects where view.window === window || view.superview === window {
            if view.transform != .identity {
                view.transform = .identity
            }
            if view === rootView {
                if let savedMask = savedRootAutoresizingMask {
                    view.autoresizingMask = savedMask
                    savedRootAutoresizingMask = nil
                } else if view.autoresizingMask.isEmpty {
                    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                }
            } else if view.autoresizingMask.isEmpty {
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
            view.frame = view.superview?.bounds ?? window.bounds
            view.setNeedsLayout()
        }
        scaledViews.removeAllObjects()

        if let rootView = rootView {
            let targetFrame = rootView.superview?.bounds ?? window.bounds
            if rootView.transform != .identity {
                rootView.transform = .identity
                if let savedMask = savedRootAutoresizingMask {
                    rootView.autoresizingMask = savedMask
                    savedRootAutoresizingMask = nil
                } else if rootView.autoresizingMask.isEmpty {
                    rootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                }
                rootView.frame = targetFrame
                rootView.setNeedsLayout()
            } else if abs(rootView.frame.width - targetFrame.width) > 0.5
                || abs(rootView.frame.height - targetFrame.height) > 0.5
                || abs(rootView.frame.origin.x) > 0.5
                || abs(rootView.frame.origin.y) > 0.5 {
                if savedRootAutoresizingMask != nil {
                    rootView.autoresizingMask = savedRootAutoresizingMask ?? [.flexibleWidth, .flexibleHeight]
                    savedRootAutoresizingMask = nil
                }
                rootView.frame = targetFrame
                rootView.setNeedsLayout()
            }
        }
        for subview in window.subviews where subview !== rootView {
            clampDirectWindowSubviewIfNeeded(subview, in: window)
        }
    }

    func clampDirectWindowSubviewIfNeeded(_ subview: UIView, in window: UIWindow) {
        if Toast.hintView.contains(subview) || subview is CircleMenu { return }
        let cls = NSStringFromClass(type(of: subview))
        if cls.contains("PlayTools") || cls.contains("Keyboard") { return }

        let rootView = window.rootViewController?.view
        let isRootHost = subview === rootView
            || cls == "UITransitionView"
            || (rootView?.isDescendant(of: subview) ?? false)
        let sceneBounds = window.windowScene?.coordinateSpace.bounds ?? .zero
        let matchesScene = sceneBounds.width > 1 && sceneBounds.height > 1
            && abs(subview.frame.width - sceneBounds.width) <= 6
            && abs(subview.frame.height - sceneBounds.height) <= 6
        let exceedsFullCanvas = subview.frame.width > window.bounds.width + 1
            && subview.frame.height > window.bounds.height + 1

        guard isRootHost || matchesScene || exceedsFullCanvas else {
            if subview.frame.height >= 0,
               abs(subview.frame.origin.x) <= 1,
               subview.frame.width > window.bounds.width + 1 {
                var clamped = subview.frame
                clamped.size.width = window.bounds.width
                subview.frame = clamped
            }
            return
        }

        if subview.transform != .identity {
            subview.transform = .identity
        }
        if !subview.translatesAutoresizingMaskIntoConstraints
            && !window.constraints.contains(where: { $0.firstItem === subview || $0.secondItem === subview }) {
            subview.translatesAutoresizingMaskIntoConstraints = true
        }
        if subview.autoresizingMask.isEmpty {
            subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        if abs(subview.frame.width - window.bounds.width) > 0.5
            || abs(subview.frame.height - window.bounds.height) > 0.5
            || abs(subview.frame.origin.x) > 0.5
            || abs(subview.frame.origin.y) > 0.5 {
            subview.frame = window.bounds
            subview.setNeedsLayout()
            subview.layoutIfNeeded()
        }
        if isRootHost, let rv = rootView, rv.superview === subview {
            clampSceneSizedDirectChildren(of: rv, sceneBounds: sceneBounds)
        } else if subview === rootView {
            clampSceneSizedDirectChildren(of: subview, sceneBounds: sceneBounds)
        }
    }

    func clampWindowSubviewsToBounds(_ window: UIWindow) {
        let sceneBounds = window.windowScene?.coordinateSpace.bounds ?? .zero
        for subview in window.subviews {
            clampDirectWindowSubviewIfNeeded(subview, in: window)
        }
        if let rv = window.rootViewController?.view {
            clampSceneSizedDirectChildren(of: rv, sceneBounds: sceneBounds)
        }
    }

    func clampSceneSizedDirectChildren(of parent: UIView, sceneBounds: CGRect) {
        guard parent.bounds.width > 1, parent.bounds.height > 1 else { return }
        for child in parent.subviews {
            if child is UIScrollView || Toast.hintView.contains(child) || child is CircleMenu { continue }
            let cls = NSStringFromClass(type(of: child))
            if cls.contains("PlayTools") || cls.contains("Keyboard") { continue }
            let matchesScene = sceneBounds.width > parent.bounds.width + 2
                && abs(child.frame.width - sceneBounds.width) <= 6
                && abs(child.frame.height - sceneBounds.height) <= 6
            let exceedsFull = child.frame.width > parent.bounds.width + 4
                && child.frame.height > parent.bounds.height + 4
            if matchesScene || exceedsFull {
                if child.transform != .identity { child.transform = .identity }
                if child.autoresizingMask.isEmpty {
                    child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                }
                child.frame = parent.bounds
                child.setNeedsLayout()
                child.layoutIfNeeded()
            }
        }
    }

    func resolveContainerBounds(
        for window: UIWindow,
        candidate: CGRect,
        logicalSize: CGSize
    ) -> CGRect {
        let sceneRect = window.windowScene?.coordinateSpace.bounds
        let candidateDiffersFromLogical = abs(candidate.width - logicalSize.width) > 0.5
            || abs(candidate.height - logicalSize.height) > 0.5
        if candidate.width > 1, candidate.height > 1,
           candidate.origin == .zero, candidateDiffersFromLogical {
            return candidate
        }
        if let s = sceneRect, s.width > 1, s.height > 1 {
            return s
        }
        if candidate.width > 1, candidate.height > 1 {
            return candidate
        }
        return CGRect(origin: .zero, size: logicalSize)
    }

    func applyScaledWindowGeometry(
        to window: UIWindow,
        logicalSize: CGSize,
        containerBounds: CGRect
    ) {
        guard !isApplyingScaledLayout,
              containerBounds.width > 1, containerBounds.height > 1,
              logicalSize.width > 1, logicalSize.height > 1 else { return }

        let targetBounds = CGRect(origin: .zero, size: logicalSize)
        let scale = Swift.min(
            containerBounds.width / logicalSize.width,
            containerBounds.height / logicalSize.height
        )
        let targetCenter = CGPoint(x: containerBounds.midX, y: containerBounds.midY)

        let targetTransform = CGAffineTransform(scaleX: scale, y: scale)
        let needsBounds = abs(window.bounds.width - targetBounds.width) > 0.25
            || abs(window.bounds.height - targetBounds.height) > 0.25
            || abs(window.bounds.origin.x) > 0.25
            || abs(window.bounds.origin.y) > 0.25
        let needsCenter = abs(window.center.x - targetCenter.x) > 0.25
            || abs(window.center.y - targetCenter.y) > 0.25
        let currentTransform = window.transform
        let needsScale = abs(currentTransform.a - scale) > 0.001 || abs(currentTransform.d - scale) > 0.001
            || abs(currentTransform.b) > 0.001 || abs(currentTransform.c) > 0.001
            || abs(currentTransform.tx) > 0.001 || abs(currentTransform.ty) > 0.001

        guard needsBounds || needsCenter || needsScale else { return }

        scaledWindows.add(window)
        isApplyingScaledLayout = true
        defer { isApplyingScaledLayout = false }

        if needsBounds { window.bounds = targetBounds }
        if needsCenter { window.center = targetCenter }
        if needsScale { window.transform = targetTransform }
    }

    func applyScaledCanvasToScene(containing window: UIWindow, logicalSize: CGSize) {
        let sceneWindows = window.windowScene?.windows ?? []
        for appWindow in sceneWindows where appWindow !== window && isEligiblePrimaryWindow(appWindow) {
            applyScaledCanvas(to: appWindow, logicalSize: logicalSize)
        }
        applyScaledCanvas(to: window, logicalSize: logicalSize)
    }

    func applyScaledCanvas(to window: UIWindow, logicalSize: CGSize) {
        scaledWindows.add(window)
        let didChangeBounds = abs(window.bounds.width - logicalSize.width) > 0.5
            || abs(window.bounds.height - logicalSize.height) > 0.5
        let sceneBounds = window.windowScene?.coordinateSpace.bounds ?? window.bounds
        let container = (sceneBounds.width > 1 && sceneBounds.height > 1)
            ? sceneBounds
            : CGRect(origin: .zero, size: logicalSize)
        applyScaledWindowGeometry(to: window, logicalSize: logicalSize, containerBounds: container)
        resetChildViewTransformsIfNeeded(in: window)
        clampWindowSubviewsToBounds(window)
        if let savedBg = originalWindowBackground {
            window.backgroundColor = savedBg
            originalWindowBackground = nil
        }
        if didChangeBounds {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            for subview in window.subviews where !Toast.hintView.contains(subview) && !(subview is CircleMenu) {
                recursivelyRelayout(subview)
            }
            scheduleAdaptiveRelayout(for: window)
        }
    }

    func scheduleFinalAdaptiveLayoutIfNeeded(for window: UIWindow, delay: TimeInterval) {
        relayoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self = self,
                  !self.isHostLiveResizing,
                  let win = window ?? self.activePrimaryWindow,
                  win === self.activePrimaryWindow,
                  self.displayMode == .adaptive else { return }
            self.lastRelayoutTime = CFAbsoluteTimeGetCurrent()
            if win.bounds.width >= 100 && win.bounds.height >= 100 {
                self.lastAdaptiveLayoutSize = win.bounds.size
                self.lastAdaptiveBounds = CGRect(origin: .zero, size: win.bounds.size)
            }
            win.setNeedsLayout()
            win.layoutIfNeeded()
        }
        relayoutWorkItem = item
        if delay <= 0 {
            DispatchQueue.main.async(execute: item)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func scheduleAdaptiveRelayout(for window: UIWindow) {
        relayoutWorkItem?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        let delay = (now - lastRelayoutTime) < 0.05 ? 0.05 : 0.0
        let item = DispatchWorkItem { [weak self, weak window] in
            guard let self = self, let win = window else { return }
            self.lastRelayoutTime = CFAbsoluteTimeGetCurrent()
            if case .scaled = self.displayMode {
                self.clampWindowSubviewsToBounds(win)
            }
            win.setNeedsLayout()
            win.layoutIfNeeded()
            for subview in win.subviews {
                if Toast.hintView.contains(subview) || subview is CircleMenu { continue }
                self.recursivelyRelayout(subview)
            }
        }
        relayoutWorkItem = item
        if delay == 0 {
            DispatchQueue.main.async(execute: item)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func recursivelyRelayout(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if let collection = view as? UICollectionView {
            collection.collectionViewLayout.invalidateLayout()
            collection.setNeedsLayout()
            collection.layoutIfNeeded()
        } else if let table = view as? UITableView {
            table.setNeedsLayout()
            table.layoutIfNeeded()
            for cell in table.visibleCells {
                cell.setNeedsLayout()
                cell.layoutIfNeeded()
            }
        }
        for subview in view.subviews {
            recursivelyRelayout(subview)
        }
    }

    func scheduleRuntimeFallbackCheck(delay: TimeInterval) {
        fallbackWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.evaluateRuntimeNonAdaptiveFallback()
        }
        fallbackWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func evaluateRuntimeNonAdaptiveFallback() {
        guard shouldAllowRuntimeFallback,
              !didTriggerRuntimeFallback,
              let win = activePrimaryWindow,
              let rootView = win.rootViewController?.view,
              win.bounds.width >= 500 else { return }

        let overflowFound = hasNonScrollableWidthOverflow(in: rootView, window: win, threshold: 24)
        guard overflowFound else { return }

        didTriggerRuntimeFallback = true
        let useLandscape = appCapabilities.hasLandscape && !appCapabilities.hasPortrait
        let ratioW: CGFloat = useLandscape ? 16 : 9
        let ratioH: CGFloat = useLandscape ? 9 : 16
        let logical = useLandscape ? CGSize(width: 1280, height: 720) : CGSize(width: 414, height: 736)
        let minSize = Self.minSizeForRatio(ratioW: ratioW, ratioH: ratioH)

        displayMode = .scaled(logicalSize: logical, ratioW: ratioW, ratioH: ratioH)
        applySceneSizeRestrictions(for: win.windowScene)
        AKInterface.shared?.applyWindowAspectLock(
            width: ratioW,
            height: ratioH,
            minWidth: minSize.width,
            minHeight: minSize.height
        )
        applyScaledCanvasToScene(containing: win, logicalSize: logical)
    }

    func hasNonScrollableWidthOverflow(in view: UIView, window: UIWindow, threshold: CGFloat) -> Bool {
        if view.isHidden || view.alpha <= 0.05 || view.bounds.width < 1 || view.bounds.height < 1 {
            return false
        }
        if !(view.layer.animationKeys()?.isEmpty ?? true) {
            return false
        }
        if isHorizontalScrollOrTabView(view) {
            return false
        }
        let rect = view.convert(view.bounds, to: window)
        let winBounds = window.bounds
        if rect.maxX <= 0 || rect.minX >= winBounds.width {
            return false
        }
        let overlapsVisibly = rect.minX < winBounds.width - 8 && rect.maxX > 8
            && rect.minY < winBounds.height - 4 && rect.maxY > 4
        if overlapsVisibly && rect.width >= 120 && rect.height >= 80 {
            if rect.maxX > winBounds.width + threshold || rect.minX < -threshold {
                return true
            }
        }
        let isBoundedClip = view !== window.rootViewController?.view && view.clipsToBounds
            && rect.minX >= -8 && rect.maxX <= winBounds.width + 8
        if isBoundedClip && rect.width < winBounds.width * 0.92 {
            return false
        }
        for subview in view.subviews {
            if hasNonScrollableWidthOverflow(in: subview, window: window, threshold: threshold) {
                return true
            }
        }
        return false
    }

    func isHorizontalScrollOrTabView(_ view: UIView) -> Bool {
        let cls = NSStringFromClass(type(of: view))
        if cls.contains("TabScroll") || cls.contains("QueuingScrollView")
            || cls.contains("PageView") || cls.contains("Pager")
            || cls.contains("Carousel") || cls.contains("Banner") {
            return true
        }
        guard let scrollView = view as? UIScrollView else { return false }
        if isHorizontalScrollCapable(scrollView) {
            return true
        }
        if scrollView.contentInset.left > 1 || scrollView.contentInset.right > 1
            || abs(scrollView.contentOffset.x) > 1 {
            return true
        }
        return scrollView.isScrollEnabled && !(scrollView is UITableView) && scrollView.bounds.height <= 90
    }

    func isHorizontalScrollCapable(_ scrollView: UIScrollView) -> Bool {
        if scrollView.contentSize.width > scrollView.bounds.width + 2 || scrollView.alwaysBounceHorizontal {
            return true
        }
        if let collection = scrollView as? UICollectionView,
           let flow = collection.collectionViewLayout as? UICollectionViewFlowLayout,
           flow.scrollDirection == .horizontal {
            return true
        }
        let cls = NSStringFromClass(type(of: scrollView))
        return cls.contains("QueuingScrollView") || cls.contains("PageView")
            || cls.contains("TabScroll") || cls.contains("Pager")
    }
}

private extension PlayScreen {
    var automationDirURL: URL {
        let bundleId = Bundle.main.bundleIdentifier
            ?? (Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String) ?? "unknown"
        return URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("Automation")
            .appendingPathComponent(bundleId)
    }

    func startAutomationServerIfNeeded() {
        guard ProcessInfo.processInfo.environment["PLAYTOOLS_AUTOMATION"] == "1" else { return }
        try? FileManager.default.createDirectory(at: automationDirURL, withIntermediateDirectories: true)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            self?.tickAutomation()
        }
        automationTimer = timer
        timer.resume()
    }

    func tickAutomation() {
        let cmdURL = automationDirURL.appendingPathComponent("cmd.json")
        if FileManager.default.fileExists(atPath: cmdURL.path),
           let data = try? Data(contentsOf: cmdURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let action = (json["action"] as? String) ?? (json["cmd"] as? String),
           action == "listWindows" {
            try? FileManager.default.removeItem(at: cmdURL)
            writeJSON(buildWindowInventoryPayload(), to: automationDirURL.appendingPathComponent("state.json"))
            return
        }

        guard let win = activePrimaryWindow, win.rootViewController?.view != nil else { return }
        if !didWriteReadyFile {
            didWriteReadyFile = true
            let readyPayload: [String: Any] = [
                "ready": true,
                "bundleId": Bundle.main.bundleIdentifier ?? "",
                "pid": ProcessInfo.processInfo.processIdentifier,
                "mode": displayMode.name,
                "timestamp": Date().timeIntervalSince1970
            ]
            writeJSON(readyPayload, to: automationDirURL.appendingPathComponent("ready.json"))
        }

        guard FileManager.default.fileExists(atPath: cmdURL.path),
              let data = try? Data(contentsOf: cmdURL) else { return }
        try? FileManager.default.removeItem(at: cmdURL)

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let action = (json["action"] as? String) ?? (json["cmd"] as? String) else {
            writeJSON(["error": "invalid cmd.json"], to: automationDirURL.appendingPathComponent("state.json"))
            return
        }
        executeAutomationAction(action, params: json, in: win)
    }

    func executeAutomationAction(_ action: String, params: [String: Any], in window: UIWindow) {
        let stateURL = automationDirURL.appendingPathComponent("state.json")
        switch action {
        case "listWindows":
            writeJSON(buildWindowInventoryPayload(), to: stateURL)
        case "dump":
            writeJSON(buildDumpPayload(action: "dump", window: window), to: stateURL)
        case "dumpTree":
            let maxDepth = (params["maxDepth"] as? NSNumber)?.intValue ?? 28
            let maxNodes = (params["maxNodes"] as? NSNumber)?.intValue ?? 1200
            writeJSON(
                buildTreeDumpPayload(window: window, maxDepth: maxDepth, maxNodes: maxNodes),
                to: stateURL
            )
        case "tap":
            let x = (params["x"] as? NSNumber)?.doubleValue ?? Double(window.bounds.midX)
            let y = (params["y"] as? NSNumber)?.doubleValue ?? Double(window.bounds.midY)
            performAutomationTap(at: CGPoint(x: x, y: y), in: window, stateURL: stateURL)
        case "swipe":
            let x1 = (params["x1"] as? NSNumber)?.doubleValue ?? Double(window.bounds.midX)
            let y1 = (params["y1"] as? NSNumber)?.doubleValue ?? Double(window.bounds.height * 0.7)
            let x2 = (params["x2"] as? NSNumber)?.doubleValue ?? Double(window.bounds.midX)
            let y2 = (params["y2"] as? NSNumber)?.doubleValue ?? Double(window.bounds.height * 0.3)
            let dur = (params["duration"] as? NSNumber)?.doubleValue ?? 0.25
            performAutomationSwipe(
                from: CGPoint(x: x1, y: y1),
                to: CGPoint(x: x2, y: y2),
                duration: dur,
                in: window,
                stateURL: stateURL
            )
        case "setMode":
            performAutomationSetMode(params: params, in: window, stateURL: stateURL)
        #if PLAYTOOLS_FRAMEWORK_PROBES
        case "selftestAuthorization":
            guard PlayToolsSelfTest.isRequested, PlayToolsSelfTest.isContractFixture,
                  getenv("PLAYTOOLS_SELFTEST_AUTHORIZATION").map({ strcmp($0, "1") == 0 }) == true,
                  let operation = params["operation"] as? String else {
                writeJSON(["error": "Explicit authorization probe launch and operation required"], to: stateURL)
                return
            }
            PlayToolsSelfTest.authorizationReport(operation: operation, window: window) { [weak self] report in
                self?.writeJSON(report, to: stateURL)
            }
        case "selftestPresentations":
            guard PlayToolsSelfTest.isRequested, PlayToolsSelfTest.isContractFixture else {
                writeJSON(["error": "Marked contract fixture required"], to: stateURL)
                return
            }
            PlayToolsSelfTest.presentationReport(window: window) { [weak self] report in
                self?.writeJSON(report, to: stateURL)
            }
        #endif
        case "selftestGeometry":
            guard PlayToolsSelfTest.isRequested else {
                writeJSON(["error": "PLAYTOOLS_SELFTEST=1 required"], to: stateURL)
                return
            }
            if params["secondWindow"] as? Bool == true {
                guard PlayToolsSelfTest.isContractFixture, let scene = window.windowScene else {
                    writeJSON(["error": "Marked contract fixture with a window scene required"], to: stateURL)
                    return
                }
                let secondary = testSecondGeometryWindow(primary: window, scene: scene)
                writeJSON(PlayToolsSelfTest.geometryReport(window: window, secondary: secondary), to: stateURL)
            } else {
                writeJSON(PlayToolsSelfTest.geometryReport(window: window, secondary: []), to: stateURL)
            }
        default:
            writeJSON(["error": "unknown action: \(action)"], to: stateURL)
        }
    }

    func testSecondGeometryWindow(primary: UIWindow, scene: UIWindowScene)
        -> [(name: String, passed: Bool, detail: String)] {
        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = UIWindow.Level(rawValue: primary.windowLevel.rawValue + 1)
        overlay.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        let button = UIButton(type: .system)
        button.setTitle("Contract test", for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor, constant: 40),
            button.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor, constant: -50),
            button.widthAnchor.constraint(equalToConstant: 120),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])
        overlay.rootViewController = controller
        overlay.isHidden = false
        defer {
            overlay.isHidden = true
            overlay.rootViewController = nil
            overlay.windowScene = nil
        }
        overlay.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let buttonPoint = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: overlay)
        let primaryPoint = overlay.convert(buttonPoint, to: primary)
        let target = resolveHitTarget(for: primaryPoint, primary: primary)
        let hitButton = target.window === overlay && (target.hitView === button || target.hitView.isDescendant(of: button))
        var checks = [("geometry.secondWindow.hitTest", hitButton,
                       "Expected fixture button, hit \(type(of: target.hitView)) at \(target.point)")]
        if case .scaled = displayMode {
            checks.append(("geometry.secondWindow.scaledAlignment",
                           abs(overlay.bounds.width - primary.bounds.width) <= 1 &&
                               abs(overlay.bounds.height - primary.bounds.height) <= 1 &&
                               abs(overlay.transform.a - primary.transform.a) <= 0.01 &&
                               abs(overlay.transform.d - primary.transform.d) <= 0.01,
                           "Primary \(primary.bounds) / \(primary.transform), "
                               + "overlay \(overlay.bounds) / \(overlay.transform)"))
            do {
                let statusBar = UIView(
                    frame: CGRect(x: 0, y: 0, width: overlay.bounds.width + 10, height: 0)
                )
                overlay.addSubview(statusBar)
                defer { statusBar.removeFromSuperview() }
                clampDirectWindowSubviewIfNeeded(statusBar, in: overlay)
                let postStatusTarget = resolveHitTarget(for: primaryPoint, primary: primary)
                let hitAfterStatus = postStatusTarget.window === overlay
                    && (postStatusTarget.hitView === button
                        || postStatusTarget.hitView.isDescendant(of: button))
                let zeroHeightOK = statusBar.frame.height <= 0.5
                    && statusBar.frame.width <= overlay.bounds.width + 1
                    && hitAfterStatus
                checks.append(("geometry.scaled.zeroHeightStatusBarNonBlocking", zeroHeightOK,
                               "statusBarFrame=\(statusBar.frame), overlayBounds=\(overlay.bounds), "
                                   + "hit=\(type(of: postStatusTarget.hitView))"))
            }
            do {
                let oversized = UIView(
                    frame: CGRect(
                        x: 0,
                        y: 0,
                        width: overlay.bounds.width + 20,
                        height: overlay.bounds.height + 20
                    )
                )
                overlay.addSubview(oversized)
                defer { oversized.removeFromSuperview() }
                clampDirectWindowSubviewIfNeeded(oversized, in: overlay)
                let oversizedOK = abs(oversized.frame.width - overlay.bounds.width) <= 1
                    && abs(oversized.frame.height - overlay.bounds.height) <= 1
                checks.append(("geometry.scaled.oversizedFullscreenClamped", oversizedOK,
                               "oversizedFrame=\(oversized.frame), overlayBounds=\(overlay.bounds)"))
            }
        }
        let offscreen = UIWindow(frame: CGRect(x: -10000, y: -10000, width: 320, height: 480))
        offscreen.windowScene = scene
        offscreen.windowLevel = .statusBar
        offscreen.rootViewController = UIViewController()
        offscreen.isHidden = false
        defer {
            offscreen.isHidden = true
            offscreen.rootViewController = nil
            offscreen.windowScene = nil
        }
        offscreen.layoutIfNeeded()
        let preservedOffscreen = !offscreen.frame.intersects(scene.coordinateSpace.bounds)
            && activePrimaryWindow !== offscreen
        checks.append(("geometry.offscreenWindow.preserved", preservedOffscreen,
                       "offscreenFrame=\(offscreen.frame), sceneBounds=\(scene.coordinateSpace.bounds), "
                           + "primaryIsOffscreen=\(activePrimaryWindow === offscreen)"))
        return checks
    }

    func performAutomationTap(at point: CGPoint, in window: UIWindow, stateURL: URL) {
        let target = resolveHitTarget(for: point, primary: window)
        let tid = PTFakeMetaTouch.fakeTouchId(
            -1, at: target.point, with: .began, in: target.window, on: target.hitView
        )
        let hitWin = target.window
        let hitView = target.hitView
        let targetPoint = target.point
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window, weak hitWin, weak hitView] in
            if tid >= 0 {
                _ = PTFakeMetaTouch.fakeTouchId(
                    tid, at: targetPoint, with: .ended, in: hitWin, on: hitView
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let self = self, let win = window ?? self.activePrimaryWindow else { return }
                var payload = self.buildDumpPayload(action: "tap", window: win)
                payload["ok"] = true
                payload["tapPoint"] = ["x": point.x, "y": point.y]
                if let hw = hitWin {
                    payload["hitWindowClass"] = NSStringFromClass(type(of: hw))
                }
                if let hv = hitView {
                    payload["hitViewClass"] = NSStringFromClass(type(of: hv))
                }
                self.writeJSON(payload, to: stateURL)
            }
        }
    }

    func performAutomationSwipe(
        from start: CGPoint,
        to end: CGPoint,
        duration: TimeInterval,
        in window: UIWindow,
        stateURL: URL
    ) {
        let target = resolveHitTarget(for: start, primary: window)
        let targetEnd = convertPoint(end, from: window, to: target.window)
        let hitWin = target.window
        let hitView = target.hitView
        let tid = PTFakeMetaTouch.fakeTouchId(
            -1, at: target.point, with: .began, in: hitWin, on: hitView
        )
        guard tid >= 0 else {
            writeJSON(["action": "swipe", "ok": false], to: stateURL)
            return
        }
        let steps = 10
        let safeDuration = Swift.max(0.12, duration)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let pt = CGPoint(
                x: target.point.x + (targetEnd.x - target.point.x) * t,
                y: target.point.y + (targetEnd.y - target.point.y) * t
            )
            let delay = 0.03 + safeDuration * Double(step) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak hitWin, weak hitView] in
                _ = PTFakeMetaTouch.fakeTouchId(tid, at: pt, with: .moved, in: hitWin, on: hitView)
            }
        }
        let endDelay = 0.03 + safeDuration + 0.03
        DispatchQueue.main.asyncAfter(deadline: .now() + endDelay) {
            [weak self, weak window, weak hitWin, weak hitView] in
            _ = PTFakeMetaTouch.fakeTouchId(tid, at: targetEnd, with: .ended, in: hitWin, on: hitView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self = self, let win = window ?? self.activePrimaryWindow else { return }
                var payload = self.buildDumpPayload(action: "swipe", window: win)
                payload["ok"] = true
                self.writeJSON(payload, to: stateURL)
            }
        }
    }

    func performAutomationSetMode(params: [String: Any], in window: UIWindow, stateURL: URL) {
        let requestedMode = (params["mode"] as? String)?.lowercased() ?? "adaptive"
        if requestedMode == "adaptive" {
            displayMode = .adaptive
            didTriggerRuntimeFallback = false
            applySceneSizeRestrictions(for: window.windowScene)
            AKInterface.shared?.clearWindowAspectLock(minWidth: 360, minHeight: 540)
            resetScaledTransformsIfNeeded(in: window)
            for scaledWindow in scaledWindows.allObjects {
                resetScaledTransformsIfNeeded(in: scaledWindow)
            }
            lastAdaptiveBounds = CGRect(origin: .zero, size: window.bounds.size)
            scheduleAdaptiveRelayout(for: window)
        } else {
            let preset = params["preset"] as? String
            let (logical, ratioW, ratioH) = resolveModePreset(preset: preset, params: params)
            let minSize = Self.minSizeForRatio(ratioW: ratioW, ratioH: ratioH)
            displayMode = .scaled(logicalSize: logical, ratioW: ratioW, ratioH: ratioH)
            applySceneSizeRestrictions(for: window.windowScene)
            AKInterface.shared?.applyWindowAspectLock(
                width: ratioW,
                height: ratioH,
                minWidth: minSize.width,
                minHeight: minSize.height
            )
            applyScaledCanvasToScene(containing: window, logicalSize: logical)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak window] in
            guard let self = self, let win = window ?? self.activePrimaryWindow else { return }
            self.writeJSON(self.buildDumpPayload(action: "setMode", window: win), to: stateURL)
        }
    }

    func resolveModePreset(preset: String?, params: [String: Any]) -> (CGSize, CGFloat, CGFloat) {
        switch preset {
        case "16:9": return (CGSize(width: 1280, height: 720), 16, 9)
        case "3:4": return (CGSize(width: 768, height: 1024), 3, 4)
        case "4:3": return (CGSize(width: 1024, height: 768), 4, 3)
        case "9:16": return (CGSize(width: 414, height: 736), 9, 16)
        default:
            let w = (params["width"] as? NSNumber)?.doubleValue ?? 414
            let h = (params["height"] as? NSNumber)?.doubleValue ?? 736
            let rW = (params["ratioW"] as? NSNumber)?.doubleValue ?? w
            let rH = (params["ratioH"] as? NSNumber)?.doubleValue ?? h
            return (CGSize(width: w, height: h), CGFloat(rW), CGFloat(rH))
        }
    }

    func isAutomationInspectableWindow(_ win: UIWindow) -> Bool {
        if win === EditorController.shared.editorWindow { return false }
        if win.isHidden || win.alpha <= 0.01 { return false }
        if isOffscreenWindow(win) { return false }
        if win.bounds.width < 4 || win.bounds.height < 4 { return false }
        if win.subviews.isEmpty && win.rootViewController == nil { return false }
        let cls = NSStringFromClass(type(of: win))
        if cls.contains("Keyboard") || cls.contains("TextEffects")
            || cls.contains("Snapshot") || cls.contains("Menu")
            || cls.contains("StatusBar") || cls.contains("PlayTools") {
            return false
        }
        return true
    }

    func frontToBackAutomationWindows(primary: UIWindow) -> [UIWindow] {
        let sceneWindows = primary.windowScene?.windows ?? [primary]
        let enumerated = sceneWindows.enumerated().filter { isAutomationInspectableWindow($0.element) }
        let sorted = enumerated.sorted { lhs, rhs in
            if lhs.element.windowLevel != rhs.element.windowLevel {
                return lhs.element.windowLevel.rawValue > rhs.element.windowLevel.rawValue
            }
            return lhs.offset > rhs.offset
        }.map { $0.element }
        return sorted.isEmpty ? [primary] : sorted
    }

    func convertPoint(_ point: CGPoint, from source: UIWindow, to target: UIWindow) -> CGPoint {
        source === target ? point : source.convert(point, to: target)
    }

    func convertRect(_ rect: CGRect, from source: UIWindow, to target: UIWindow) -> CGRect {
        source === target ? rect : source.convert(rect, to: target)
    }

    func resolveHitTarget(
        for pointInPrimary: CGPoint,
        primary: UIWindow
    ) -> (window: UIWindow, point: CGPoint, hitView: UIView) {
        for win in frontToBackAutomationWindows(primary: primary) {
            let pt = convertPoint(pointInPrimary, from: primary, to: win)
            guard win.bounds.contains(pt) else { continue }
            if let hit = win.hitTest(pt, with: nil) {
                return (win, pt, hit)
            }
        }
        let fallback = primary.hitTest(pointInPrimary, with: nil)
            ?? primary.rootViewController?.view ?? primary
        return (primary, pointInPrimary, fallback)
    }

    func buildDumpPayload(action: String, window: UIWindow) -> [String: Any] {
        let rootView = window.rootViewController?.view
        let rootFrameInWindow = rootView.map { $0.convert($0.bounds, to: window) } ?? .zero
        let rootScale: CGFloat = {
            guard let rv = rootView, rv.bounds.width > 0.5 else { return 1.0 }
            let effectiveScale = rootFrameInWindow.width / rv.bounds.width
            return effectiveScale > 0.01 ? effectiveScale : hypot(rv.transform.a, rv.transform.b)
        }()
        let windowScale = hypot(window.transform.a, window.transform.b)
        let nsFrame = AKInterface.shared?.windowFrame ?? .zero
        let nsContent = AKInterface.shared?.contentLayoutRect ?? .zero
        let canvasRect = window.bounds
        let windows = frontToBackAutomationWindows(primary: window)
        var clipped: [[String: Any]] = []
        var elements: [[String: Any]] = []
        for win in windows {
            let roots = win.subviews.isEmpty
                ? (win.rootViewController?.view.map { [$0] } ?? [])
                : win.subviews.reversed()
            for root in roots {
                if Toast.hintView.contains(root) || root is CircleMenu { continue }
                if win === window || !NSStringFromClass(type(of: win)).hasPrefix("_UI") {
                    collectClippedViews(
                        in: root,
                        sourceWindow: win,
                        primaryWindow: window,
                        canvasRect: canvasRect,
                        insideHScroll: false,
                        insideVScroll: false,
                        out: &clipped
                    )
                }
                collectInteractiveElements(
                    in: root,
                    sourceWindow: win,
                    primaryWindow: window,
                    out: &elements
                )
            }
        }
        var payload: [String: Any] = [
            "action": action,
            "timestamp": Date().timeIntervalSince1970,
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "mode": displayMode.name,
            "smartAdaptive": PlaySettings.shared.smartAdaptive,
            "runtimeFallbackTriggered": didTriggerRuntimeFallback,
            "screenBounds": rectDict(UIScreen.main.bounds),
            "nativeScreenBounds": rectDict(UIScreen.main.nativeBounds),
            "windowBounds": rectDict(window.bounds),
            "windowFrameInScene": rectDict(window.frame),
            "windowTransformScale": windowScale,
            "rootViewBounds": rectDict(rootView?.bounds ?? .zero),
            "rootViewFrame": rectDict(rootFrameInWindow),
            "rootTransformScale": rootScale,
            "nsWindowFrame": rectDict(nsFrame),
            "nsContentRect": rectDict(nsContent),
            "clippedViews": clipped,
            "clippedViewCount": clipped.count,
            "interactiveElements": elements
        ]
        if case .scaled(let logical, let rW, let rH) = displayMode {
            payload["logicalSize"] = ["width": logical.width, "height": logical.height]
            payload["ratio"] = ["width": rW, "height": rH]
        }
        return payload
    }

    func buildTreeDumpPayload(window: UIWindow, maxDepth: Int, maxNodes: Int) -> [String: Any] {
        var remaining = maxNodes
        let windows = frontToBackAutomationWindows(primary: window)
        var winPayloads: [[String: Any]] = []
        for win in windows {
            let roots = win.subviews.isEmpty
                ? (win.rootViewController?.view.map { [$0] } ?? [])
                : win.subviews
            let treeNodes = roots.map {
                dumpViewSubtree(
                    $0,
                    sourceWindow: win,
                    primaryWindow: window,
                    depth: 0,
                    maxDepth: maxDepth,
                    remaining: &remaining
                )
            }
            var winInfo: [String: Any] = [
                "class": NSStringFromClass(type(of: win)),
                "isPrimary": win === window,
                "windowLevel": win.windowLevel.rawValue,
                "bounds": rectDict(win.bounds),
                "frameInScene": rectDict(win.frame),
                "traitCollection": traitDict(win.traitCollection),
                "subviews": treeNodes
            ]
            if let rootVC = win.rootViewController {
                winInfo["rootViewController"] = dumpViewControllerTree(rootVC, depth: 0)
            }
            winPayloads.append(winInfo)
        }
        return [
            "action": "dumpTree",
            "timestamp": Date().timeIntervalSince1970,
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "mode": displayMode.name,
            "screenBounds": rectDict(UIScreen.main.bounds),
            "windowBounds": rectDict(window.bounds),
            "nsContentRect": rectDict(AKInterface.shared?.contentLayoutRect ?? .zero),
            "windowSceneOrientation": window.windowScene?.interfaceOrientation.rawValue ?? 0,
            "deviceOrientation": UIDevice.current.orientation.rawValue,
            "userInterfaceIdiom": UIDevice.current.userInterfaceIdiom.rawValue,
            "windowTraitCollection": traitDict(window.traitCollection),
            "topViewController": topVisibleViewController(from: window.rootViewController)
                .map { NSStringFromClass(type(of: $0)) } ?? "",
            "nodeCount": maxNodes - remaining,
            "truncated": remaining <= 0,
            "windows": winPayloads
        ]
    }

    /// Read-only inventory across connected application scenes without loading `.view`
    /// or promoting/mutating any window.
    func buildWindowInventoryPayload() -> [String: Any] {
        let appScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }

        var scenePayloads: [[String: Any]] = []
        var windowPayloads: [[String: Any]] = []

        for scene in appScenes {
            let sceneId = scene.session.persistentIdentifier
            let activationState = scene.activationState.rawValue
            var perSceneWindows: [[String: Any]] = []
            for win in scene.windows {
                let entry: [String: Any] = [
                    "class": NSStringFromClass(type(of: win)),
                    "rootViewControllerClass": win.rootViewController.map { NSStringFromClass(type(of: $0)) } ?? NSNull(),
                    "isHidden": win.isHidden,
                    "isKeyWindow": win.isKeyWindow,
                    "alpha": win.alpha,
                    "windowLevel": win.windowLevel.rawValue,
                    "frame": rectDict(win.frame),
                    "scenePersistentIdentifier": sceneId,
                    "sceneActivationState": activationState
                ]
                perSceneWindows.append(entry)
                windowPayloads.append(entry)
            }
            scenePayloads.append([
                "persistentIdentifier": sceneId,
                "role": scene.session.role.rawValue,
                "activationState": activationState,
                "windows": perSceneWindows
            ])
        }

        return [
            "action": "listWindows",
            "timestamp": Date().timeIntervalSince1970,
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "mode": displayMode.name,
            "sceneCount": scenePayloads.count,
            "windowCount": windowPayloads.count,
            "scenes": scenePayloads,
            "windows": windowPayloads
        ]
    }

    func topVisibleViewController(from vc: UIViewController?) -> UIViewController? {
        guard let vc = vc else { return nil }
        if let presented = vc.presentedViewController {
            return topVisibleViewController(from: presented)
        }
        if let nav = vc as? UINavigationController {
            return topVisibleViewController(from: nav.visibleViewController)
        }
        if let tab = vc as? UITabBarController {
            return topVisibleViewController(from: tab.selectedViewController)
        }
        if let split = vc as? UISplitViewController {
            return split.viewControllers.last.flatMap { topVisibleViewController(from: $0) } ?? split
        }
        return vc
    }

    func dumpViewControllerTree(_ vc: UIViewController, depth: Int) -> [String: Any] {
        var dict: [String: Any] = [
            "class": NSStringFromClass(type(of: vc)),
            "traitCollection": traitDict(vc.traitCollection)
        ]
        if let view = vc.viewIfLoaded {
            dict["viewBounds"] = rectDict(view.bounds)
            dict["viewFrame"] = rectDict(view.frame)
            dict["viewHidden"] = view.isHidden
            dict["viewAlpha"] = view.alpha
        }
        guard depth < 12 else { return dict }
        if !vc.children.isEmpty {
            dict["children"] = vc.children.map { dumpViewControllerTree($0, depth: depth + 1) }
        }
        if let presented = vc.presentedViewController {
            dict["presented"] = dumpViewControllerTree(presented, depth: depth + 1)
        }
        return dict
    }

    func dumpViewSubtree(
        _ view: UIView,
        sourceWindow: UIWindow,
        primaryWindow: UIWindow,
        depth: Int,
        maxDepth: Int,
        remaining: inout Int
    ) -> [String: Any] {
        if remaining <= 0 { return ["truncated": true] }
        remaining -= 1

        let rectInWin = convertRect(view.convert(view.bounds, to: sourceWindow), from: sourceWindow, to: primaryWindow)
        var node: [String: Any] = [
            "class": NSStringFromClass(type(of: view)),
            "frameInWindow": rectDict(rectInWin),
            "localFrame": rectDict(view.frame),
            "bounds": rectDict(view.bounds),
            "isHidden": view.isHidden,
            "alpha": view.alpha,
            "clipsToBounds": view.clipsToBounds,
            "traitCollection": traitDict(view.traitCollection),
            "layer": layerInfoDict(view.layer)
        ]
        if let bg = colorString(view.backgroundColor) {
            node["backgroundColor"] = bg
        }
        if view.transform != .identity {
            node["viewTransform"] = [
                "a": view.transform.a, "b": view.transform.b,
                "c": view.transform.c, "d": view.transform.d,
                "tx": view.transform.tx, "ty": view.transform.ty
            ]
        }
        if let iv = view as? UIImageView {
            var imgInfo: [String: Any] = [
                "hasImage": iv.image != nil,
                "contentMode": iv.contentMode.rawValue
            ]
            if let img = iv.image {
                imgInfo["imageSize"] = ["width": img.size.width, "height": img.size.height]
            }
            node["imageView"] = imgInfo
        }
        if let scroll = view as? UIScrollView {
            var scrollInfo: [String: Any] = [
                "contentSize": ["width": scroll.contentSize.width, "height": scroll.contentSize.height],
                "contentOffset": ["x": scroll.contentOffset.x, "y": scroll.contentOffset.y],
                "isPagingEnabled": scroll.isPagingEnabled
            ]
            if let cv = scroll as? UICollectionView {
                let layoutCls = NSStringFromClass(type(of: cv.collectionViewLayout))
                scrollInfo["collectionViewLayout"] = layoutCls
                scrollInfo["visibleCells"] = cv.visibleCells.count
                scrollInfo["sections"] = cv.numberOfSections
                let itemsPerSec = (0..<cv.numberOfSections).map { cv.numberOfItems(inSection: $0) }
                scrollInfo["itemsPerSection"] = itemsPerSec
                scrollInfo["itemsInSection0"] = itemsPerSec.first ?? 0
                if let ds = cv.dataSource {
                    scrollInfo["dataSourceClass"] = NSStringFromClass(type(of: ds))
                }
                if let del = cv.delegate {
                    scrollInfo["delegateClass"] = NSStringFromClass(type(of: del))
                }
                let lcs = cv.collectionViewLayout.collectionViewContentSize
                scrollInfo["layoutContentSize"] = ["width": lcs.width, "height": lcs.height]
                if cv.numberOfSections > 0, (itemsPerSec.first ?? 0) > 0,
                   let attrs = cv.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) {
                    scrollInfo["item0LayoutFrame"] = rectDict(attrs.frame)
                }
            }
            node["scrollView"] = scrollInfo
        }
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            node["text"] = String(text.prefix(80))
        }
        if depth < maxDepth && remaining > 0 && !view.subviews.isEmpty {
            var childNodes: [[String: Any]] = []
            for sub in view.subviews {
                if remaining <= 0 { break }
                childNodes.append(
                    dumpViewSubtree(
                        sub,
                        sourceWindow: sourceWindow,
                        primaryWindow: primaryWindow,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        remaining: &remaining
                    )
                )
            }
            node["subviews"] = childNodes
        }
        return node
    }

    func layerInfoDict(_ layer: CALayer) -> [String: Any] {
        var info: [String: Any] = [
            "class": NSStringFromClass(type(of: layer)),
            "opacity": layer.opacity,
            "masksToBounds": layer.masksToBounds,
            "isHidden": layer.isHidden,
            "hasContents": layer.contents != nil,
            "hasMask": layer.mask != nil,
            "sublayerCount": layer.sublayers?.count ?? 0,
            "transformIdentity": CATransform3DIsIdentity(layer.transform)
        ]
        if let mask = layer.mask {
            info["maskClass"] = NSStringFromClass(type(of: mask))
            info["maskBounds"] = rectDict(mask.bounds)
            info["maskFrame"] = rectDict(mask.frame)
        }
        let standaloneSublayers = (layer.sublayers ?? []).filter { !($0.delegate is UIView) }
        if !standaloneSublayers.isEmpty {
            info["standaloneSublayerCount"] = standaloneSublayers.count
            info["standaloneSublayers"] = standaloneSublayers.prefix(6).map { sub -> [String: Any] in
                [
                    "class": NSStringFromClass(type(of: sub)),
                    "frame": rectDict(sub.frame),
                    "bounds": rectDict(sub.bounds),
                    "opacity": sub.opacity,
                    "isHidden": sub.isHidden,
                    "hasContents": sub.contents != nil,
                    "hasMask": sub.mask != nil
                ]
            }
        }
        return info
    }

    func traitDict(_ tc: UITraitCollection) -> [String: Any] {
        let hClass: String = {
            switch tc.horizontalSizeClass {
            case .compact: return "compact"
            case .regular: return "regular"
            default: return "unspecified"
            }
        }()
        let vClass: String = {
            switch tc.verticalSizeClass {
            case .compact: return "compact"
            case .regular: return "regular"
            default: return "unspecified"
            }
        }()
        let idiom: String = {
            switch tc.userInterfaceIdiom {
            case .phone: return "phone"
            case .pad: return "pad"
            case .mac: return "mac"
            default: return "other(\(tc.userInterfaceIdiom.rawValue))"
            }
        }()
        return [
            "horizontalSizeClass": hClass,
            "verticalSizeClass": vClass,
            "userInterfaceIdiom": idiom
        ]
    }

    func colorString(_ color: UIColor?) -> String? {
        guard let color = color else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a)
        }
        var w: CGFloat = 0
        if color.getWhite(&w, alpha: &a) {
            return String(format: "white(%.2f,%.2f)", w, a)
        }
        return color.description
    }

    func collectClippedViews(
        in view: UIView,
        sourceWindow: UIWindow,
        primaryWindow: UIWindow,
        canvasRect: CGRect,
        insideHScroll: Bool,
        insideVScroll: Bool,
        out: inout [[String: Any]]
    ) {
        if out.count >= 50 || view.isHidden || view.alpha <= 0.05
            || view.bounds.width < 1 || view.bounds.height < 1 {
            return
        }
        let isTabOrHScroll = isHorizontalScrollOrTabView(view)
        let effectiveH = insideHScroll || isTabOrHScroll
        let rect = convertRect(view.convert(view.bounds, to: sourceWindow), from: sourceWindow, to: primaryWindow)
        recordClippedViewIfNeeded(
            view: view,
            rect: rect,
            canvasRect: canvasRect,
            insideHScroll: effectiveH,
            insideVScroll: insideVScroll,
            out: &out
        )
        let isSmallClipped = view !== sourceWindow.rootViewController?.view && view.clipsToBounds
            && rect.width < canvasRect.width * 0.85
            && rect.maxX <= canvasRect.maxX + 8 && rect.minX >= canvasRect.minX - 8
        if isSmallClipped { return }

        var nextH = effectiveH
        var nextV = insideVScroll
        if let scroll = view as? UIScrollView {
            if isHorizontalScrollCapable(scroll) { nextH = true }
            if scroll.contentSize.height > scroll.bounds.height + 2
                || scroll.alwaysBounceVertical || scroll is UITableView {
                nextV = true
            }
        }
        for subview in view.subviews {
            collectClippedViews(
                in: subview,
                sourceWindow: sourceWindow,
                primaryWindow: primaryWindow,
                canvasRect: canvasRect,
                insideHScroll: nextH,
                insideVScroll: nextV,
                out: &out
            )
        }
    }

    func recordClippedViewIfNeeded(
        view: UIView,
        rect: CGRect,
        canvasRect: CGRect,
        insideHScroll: Bool,
        insideVScroll: Bool,
        out: inout [[String: Any]]
    ) {
        let intersects = rect.minX < canvasRect.maxX - 4 && rect.maxX > canvasRect.minX + 4
            && rect.minY < canvasRect.maxY - 4 && rect.maxY > canvasRect.minY + 4
        guard intersects else { return }
        let leftOver = Swift.max(0, canvasRect.minX - rect.minX)
        let rightOver = Swift.max(0, rect.maxX - canvasRect.maxX)
        let topOver = Swift.max(0, canvasRect.minY - rect.minY)
        let bottomOver = Swift.max(0, rect.maxY - canvasRect.maxY)
        let hOver = !insideHScroll && (leftOver > 8 || rightOver > 8)
        let vOver = !insideVScroll && (topOver > 8 || bottomOver > 8)
        guard hOver || vOver else { return }
        out.append([
            "class": NSStringFromClass(type(of: view)),
            "frameInWindow": rectDict(rect),
            "overflow": [
                "left": hOver ? leftOver : 0,
                "right": hOver ? rightOver : 0,
                "top": vOver ? topOver : 0,
                "bottom": vOver ? bottomOver : 0
            ]
        ])
    }

    func collectInteractiveElements(
        in view: UIView,
        sourceWindow: UIWindow,
        primaryWindow: UIWindow,
        out: inout [[String: Any]]
    ) {
        if out.count >= 80 || view.isHidden || view.alpha <= 0.05
            || view.bounds.width < 4 || view.bounds.height < 4 {
            return
        }
        let cls = NSStringFromClass(type(of: view))
        let isActionCell = cls.contains("AlertControllerAction")
            || cls.contains("InterfaceActionRepresentation")
        let isInteractive = view.isUserInteractionEnabled && (
            view is UIControl || view is UITableViewCell || view is UICollectionViewCell
                || !(view.gestureRecognizers?.isEmpty ?? true) || view.isAccessibilityElement
                || isActionCell
        )
        if isInteractive {
            let rect = convertRect(view.convert(view.bounds, to: sourceWindow), from: sourceWindow, to: primaryWindow)
            let pt = CGPoint(x: rect.midX, y: rect.midY)
            let isLargeBackdrop = rect.width >= primaryWindow.bounds.width * 0.9
                && rect.height >= primaryWindow.bounds.height * 0.45
            if primaryWindow.bounds.contains(pt)
                && !isLargeBackdrop
                && rect.width <= primaryWindow.bounds.width * 0.98 {
                var item: [String: Any] = [
                    "class": cls,
                    "frameInWindow": rectDict(rect),
                    "pointInWindow": ["x": pt.x, "y": pt.y]
                ]
                if sourceWindow !== primaryWindow {
                    item["windowClass"] = NSStringFromClass(type(of: sourceWindow))
                }
                if let btn = view as? UIButton, let title = btn.currentTitle, !title.isEmpty {
                    item["title"] = title
                } else if let labelText = firstLabelText(in: view), !labelText.isEmpty {
                    item["title"] = labelText
                }
                if let acc = view.accessibilityLabel, !acc.isEmpty {
                    item["accessibilityLabel"] = acc
                }
                out.append(item)
            }
        }
        for subview in view.subviews.reversed() {
            collectInteractiveElements(
                in: subview,
                sourceWindow: sourceWindow,
                primaryWindow: primaryWindow,
                out: &out
            )
        }
    }

    func firstLabelText(in view: UIView) -> String? {
        if let label = view as? UILabel { return label.text }
        for sub in view.subviews {
            if let text = firstLabelText(in: sub), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    func rectDict(_ rect: CGRect) -> [String: CGFloat] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.size.width, "height": rect.size.height]
    }

    func writeJSON(_ dict: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension CGFloat {
    var relativeY: CGFloat { self / screen.height }
    var relativeX: CGFloat { self / screen.width }
    var relativeSize: CGFloat { self / screen.percent }
    var absoluteSize: CGFloat { self * screen.percent }
    var absoluteX: CGFloat { self * screen.width }
    var absoluteY: CGFloat { self * screen.height }
}

extension UIWindow {
    var nsWindow: NSObject? {
        guard let nsWindows = NSClassFromString("NSApplication")?
            .value(forKeyPath: "sharedApplication.windows") as? [AnyObject] else { return nil }
        for nsWindow in nsWindows {
            let uiWindows = nsWindow.value(forKeyPath: "uiWindows") as? [UIWindow] ?? []
            if uiWindows.contains(self) {
                return nsWindow as? NSObject
            }
        }
        return nil
    }
}
