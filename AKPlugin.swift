//
//  MacPlugin.swift
//  AKInterface
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import AppKit
import CoreGraphics
import Foundation

// Add a lightweight struct so we can decode only the flags we care about
private struct AKAppSettingsData: Codable {
    var keymapping: Bool?
    var optionScrollZoom: Bool?
    var hideTitleBar: Bool?
    var floatingWindow: Bool?
    var resolution: Int?
    var resizableAspectRatioType: Int?
    var resizableAspectRatioWidth: Int?
    var resizableAspectRatioHeight: Int?
    var layoutIdiom: Int?
    var sdkShift: Bool?
}

private struct AKAppLayoutInfo {
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
        let sdk = Self.parseSDKVersion(info["DTSDKName"] as? String)
        supportsDuoAdaptive = families.contains(1) && (sdk.major > 27 || (sdk.major == 27 && sdk.minor >= 1))
        let rawRequiresFullScreen = info["UIRequiresFullScreen"] as? Bool ?? false
        let ignoredFromStr = (info["UIRequiresFullScreenIgnoredStartingWithVersion"] as? String)
            ?? (info["UIRequiresFullScreenIgnoredStartingWithVersion"] as? NSNumber)?.stringValue
        let ignoredFrom = Self.parseSDKVersion(ignoredFromStr)
        let runtimeVer = ProcessInfo.processInfo.operatingSystemVersion
        let ignoresRequiresFullScreen = ignoredFrom.major > 0
            && (runtimeVer.majorVersion > ignoredFrom.major
                || (runtimeVer.majorVersion == ignoredFrom.major && runtimeVer.minorVersion >= ignoredFrom.minor))
        requiresFullScreen = rawRequiresFullScreen && !ignoresRequiresFullScreen
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
        isAdaptive = !prefersScaledWindow && (supportsIPad || supportsDuoAdaptive)
            && !requiresFullScreen
            && ((hasPortrait && hasLandscape) || hasScene)
    }

    private static func parseSDKVersion(_ sdkName: String?) -> (major: Int, minor: Int) {
        guard let sdk = sdkName else { return (0, 0) }
        let digits = sdk.drop { !$0.isNumber }
        let parts = digits.split(separator: ".")
        let major = parts.first.flatMap { Int($0) } ?? 0
        let minor = parts.dropFirst().first.flatMap { Int($0) } ?? 0
        return (major, minor)
    }

    var recommendedAspect: (width: CGFloat, height: CGFloat, minW: CGFloat, minH: CGFloat) {
        if hasLandscape && !hasPortrait {
            return (16, 9, 480, 270)
        }
        if supportsIPad && !families.contains(1) {
            return (3, 4, 360, 480)
        }
        return (9, 16, 270, 480)
    }
}

class AKPlugin: NSObject, Plugin {
    private static let savedFrameDefaultsKey = "PlayCover.SavedWindowFrame.v1"
    private static let temporaryDefaultWideDuoWindow = true // TEMP_TEST_DEFAULT_WIDE_DUO_WINDOW: revert when testing completes

    private let layoutInfo = AKAppLayoutInfo()
    private let configuredWindows = NSHashTable<NSWindow>.weakObjects()
    private let verifiedTargetWindows = NSHashTable<NSWindow>.weakObjects()
    private var isRestoringSavedFrame = false
    private static let globalBackChangedNotification = Notification.Name("io.playcover.PlayCover.GlobalBackSettingsChanged")
    private var globalBackSettings = AKGlobalBackSettingsData.load()
    private var globalBackQueryState: ((Bool) -> Int)?
    private var globalBackPerformBack: ((Bool) -> Bool)?
    private var globalHomeQueryState: (() -> Bool)?
    private var globalHomePerformHome: (() -> Bool)?
    private var globalBackMonitorInstalled = false
    private var globalBackPostClickWorkItem: DispatchWorkItem?
    private let globalBackAccessoryByWindow = NSMapTable<NSWindow, NSTitlebarAccessoryViewController>.weakToStrongObjects()
    private let globalBackStackByWindow = NSMapTable<NSWindow, NSStackView>.weakToStrongObjects()
    private let globalBackButtonByWindow = NSMapTable<NSWindow, AKGlobalBackTitlebarButton>.weakToStrongObjects()
    private let globalHomeButtonByWindow = NSMapTable<NSWindow, AKGlobalBackTitlebarButton>.weakToStrongObjects()

    required override init() {
        super.init()
        configureAllWindows()

        let center = NotificationCenter.default
        DistributedNotificationCenter.default().addObserver(
            forName: Self.globalBackChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.reloadGlobalBackSettingsAndRefresh()
        }
        center.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.configureAllWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.configureAllWindows()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self?.configureAllWindows()
            }
        }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didExposeNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notif in
                guard let win = notif.object as? NSWindow else { return }
                self?.configureWindowIfNeeded(win)
            }
        }

        for name in [
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.willCloseNotification
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notif in
                guard let win = notif.object as? NSWindow else { return }
                self?.saveWindowFrameIfAppropriate(win)
            }
        }

        center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] notif in
            guard let win = notif.object as? NSWindow, !win.inLiveResize else { return }
            self?.saveWindowFrameIfAppropriate(win)
        }

        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for win in self.configuredWindows.allObjects {
                self.saveWindowFrameIfAppropriate(win)
            }
        }
    }

    var screenCount: Int {
        NSScreen.screens.count
    }

    var mousePoint: CGPoint {
        primaryWindow?.mouseLocationOutsideOfEventStream ?? CGPoint()
    }

    var windowFrame: CGRect {
        primaryWindow?.frame ?? CGRect()
    }

    var contentLayoutRect: CGRect {
        primaryWindow?.contentLayoutRect ?? NSApplication.shared.windows.first?.contentLayoutRect ?? CGRect()
    }

    var isMainScreenEqualToFirst: Bool {
        NSScreen.main == NSScreen.screens.first
    }

    var mainScreenFrame: CGRect {
        NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? CGRect()
    }

    var isFullscreen: Bool {
        primaryWindow?.styleMask.contains(.fullScreen) ?? false
    }

    var isApplicationActive: Bool { NSApplication.shared.isActive }

    var hasVisibleUnminiaturizedWindow: Bool {
        NSApplication.shared.windows.contains { isMainAppWindow($0) && $0.isVisible && !$0.isMiniaturized }
    }

    var cmdPressed: Bool = false
    var cursorHideLevel = 0
    func hideCursor() {
        NSCursor.hide()
        cursorHideLevel += 1
        CGAssociateMouseAndMouseCursorPosition(0)
        warpCursor()
    }

    func hideCursorMove() {
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func warpCursor() {
        guard let firstScreen = NSScreen.screens.first else {return}
        let frame = windowFrame
        // Convert from NS coordinates to CG coordinates
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: firstScreen.frame.height - frame.midY))
    }

    func unhideCursor() {
        NSCursor.unhide()
        cursorHideLevel -= 1
        if cursorHideLevel <= 0 {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    func terminateApplication() {
        NSApplication.shared.terminate(self)
    }

    private var modifierFlag: UInt = 0
    private var optionScrollZoomEndHandler: (() -> Void)?
    private var optionScrollZoomActive = false
    private var optionScrollZoomInstalled = false

    // swiftlint:disable:next function_body_length
    func setupKeyboard(keyboard: @escaping (UInt16, Bool, Bool, Bool) -> Bool,
                       swapMode: @escaping () -> Bool) {
        guard keymappingSetting else { return }
        func checkCmd(modifier: NSEvent.ModifierFlags) -> Bool {
            if modifier.contains(.command) {
                self.cmdPressed = true
                return true
            } else if self.cmdPressed {
                self.cmdPressed = false
            }
            return false
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let consumed = keyboard(event.keyCode, true, event.isARepeat,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let consumed = keyboard(event.keyCode, false, false,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let pressed = self.modifierFlag < event.modifierFlags.rawValue
            let changed = self.modifierFlag ^ event.modifierFlags.rawValue
            self.modifierFlag = event.modifierFlags.rawValue
            let changedFlags = NSEvent.ModifierFlags(rawValue: changed)
            if pressed && changedFlags.contains(.option) {
                if swapMode() {
                    return nil
                }
                return event
            }
            let consumed = keyboard(event.keyCode, pressed, false,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
    }

    func setupMouseMoved(_ mouseMoved: @escaping (CGFloat, CGFloat) -> Bool) {
        guard keymappingSetting else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .otherMouseDragged, .rightMouseDragged]
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            let consumed = mouseMoved(event.deltaX, event.deltaY)
            if consumed {
                return nil
            }
            return event
        })
        // transpass mouse moved event when no button pressed, for traffic light button to light up
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            _ = mouseMoved(event.deltaX, event.deltaY)
            return event
        })
    }

    func setupMouseButton(left: Bool, right: Bool, _ consumed: @escaping (Int, Bool) -> Bool) {
        guard keymappingSetting else { return }
        let downType: NSEvent.EventTypeMask = left ? .leftMouseDown : right ? .rightMouseDown : .otherMouseDown
        let upType: NSEvent.EventTypeMask = left ? .leftMouseUp : right ? .rightMouseUp : .otherMouseUp

        // Helper to detect whether the event is inside any of the window "traffic-light" buttons
        func isInTrafficLightArea(_ event: NSEvent) -> Bool {
            if self.hideTitleBarSetting == false {
                return false
            }
            guard let win = event.window else { return false }
            let pointInWindow = event.locationInWindow
            let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .fullScreenButton]
            for type in buttonTypes {
                if let button = win.standardWindowButton(type) {
                    let localPoint = button.convert(pointInWindow, from: nil) // convert from window coords
                    if button.bounds.contains(localPoint) {
                        return true
                    }
                }
            }
            return false
        }

        NSEvent.addLocalMonitorForEvents(matching: downType, handler: { event in
            // Always allow clicks on the window traffic-light buttons or titlebar Back button to pass through
            if isInTrafficLightArea(event) {
                return event
            }
            if let win = event.window, self.isPointInGlobalBackButton(event.locationInWindow, window: win) {
                return event
            }

            // Detect double-clicks on the title-bar area (respecting system preference)

            if left && event.clickCount == 2, self.hideTitleBarSetting, let win = event.window {
                let contentRect = win.contentLayoutRect
                // Title-bar area is the region above contentLayoutRect
                if event.locationInWindow.y > contentRect.maxY {
                    win.performZoom(nil)
                    return nil
                }
            }

            // For traffic light buttons when fullscreen
            if let primary = self.primaryWindow, event.window != primary {
                return event
            }
            if consumed(event.buttonNumber, true) {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: upType, handler: { event in
            // Always allow releases on the traffic-light buttons or titlebar Back button to pass through
            if isInTrafficLightArea(event) {
                return event
            }
            if let win = event.window, self.isPointInGlobalBackButton(event.locationInWindow, window: win) {
                return event
            }
            if consumed(event.buttonNumber, false) {
                return nil
            }
            return event
        })
    }

    func setupScrollWheel(_ onMoved: @escaping (CGFloat, CGFloat) -> Bool) {
        guard keymappingSetting else { return }
        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.scrollWheel, handler: { event in
            var deltaX = event.scrollingDeltaX, deltaY = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                deltaX *= 16
                deltaY *= 16
            }
            let consumed = onMoved(deltaX, deltaY)
            if consumed {
                return nil
            }
            return event
        })
    }

    func urlForApplicationWithBundleIdentifier(_ value: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
    }

    func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }

    /// Convenience instance property that exposes the cached static preference.
    private var keymappingSetting: Bool { Self.akAppSettingsData?.keymapping ?? false }
    private var optionScrollZoomSetting: Bool { Self.akAppSettingsData?.optionScrollZoom ?? true }
    private var hideTitleBarSetting: Bool { Self.akAppSettingsData?.hideTitleBar ?? true }
    private var floatingWindowSetting: Bool { Self.akAppSettingsData?.floatingWindow ?? false }
    private var resolutionSetting: Int { Self.akAppSettingsData?.resolution ?? 7 }
    private var layoutIdiomSetting: Int { Self.akAppSettingsData?.layoutIdiom ?? 3 }
    private var sdkShiftSetting: Bool { Self.akAppSettingsData?.sdkShift ?? false }
    private var aspectRatioSetting: NSSize? {
        guard resolutionSetting == 6 else {
            return nil
        }
        let ratioType = Self.akAppSettingsData?.resizableAspectRatioType ?? 0
        guard ratioType != 0 else {
            return nil
        }
        let width = Self.akAppSettingsData?.resizableAspectRatioWidth ?? 0
        let height = Self.akAppSettingsData?.resizableAspectRatioHeight ?? 0
        guard width > 0 && height > 0 else {
            return nil
        }
        return NSSize(width: width, height: height)
    }

    fileprivate static var akAppSettingsData: AKAppSettingsData? = {
        if let settingsCls = (NSClassFromString("PlayTools.PlaySettings") ?? NSClassFromString("PlaySettings")) as? NSObject.Type,
           let shared = settingsCls.perform(NSSelectorFromString("shared"))?.takeUnretainedValue() as? NSObject,
           let dict = shared.perform(NSSelectorFromString("akPluginSettingsDictionary"))?.takeUnretainedValue() as? [String: Any] {
            var data = AKAppSettingsData()
            data.keymapping = (dict["keymapping"] as? NSNumber)?.boolValue
            data.optionScrollZoom = (dict["optionScrollZoom"] as? NSNumber)?.boolValue
            data.hideTitleBar = (dict["hideTitleBar"] as? NSNumber)?.boolValue
            data.floatingWindow = (dict["floatingWindow"] as? NSNumber)?.boolValue
            data.resolution = (dict["resolution"] as? NSNumber)?.intValue
            data.resizableAspectRatioType = (dict["resizableAspectRatioType"] as? NSNumber)?.intValue
            data.resizableAspectRatioWidth = (dict["resizableAspectRatioWidth"] as? NSNumber)?.intValue
            data.resizableAspectRatioHeight = (dict["resizableAspectRatioHeight"] as? NSNumber)?.intValue
            data.layoutIdiom = (dict["layoutIdiom"] as? NSNumber)?.intValue
            data.sdkShift = (dict["sdkShift"] as? NSNumber)?.boolValue
            return data
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? (Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String) ?? ""
        let settingsURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("App Settings")
            .appendingPathComponent("\(bundleIdentifier).plist")
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? PropertyListDecoder().decode(AKAppSettingsData.self, from: data) else {
            return nil
        }
        return decoded
    }()
}

extension AKPlugin {
    @objc func setupOptionScrollZoom(
        _ onZoom: @escaping (CGFloat, CGFloat, CGFloat, Bool) -> Bool,
        onEnd: @escaping () -> Void
    ) {
        guard !optionScrollZoomInstalled, optionScrollZoomSetting else { return }
        optionScrollZoomInstalled = true
        optionScrollZoomEndHandler = onEnd

        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleOptionScrollWheelEvent(event, onZoom: onZoom)
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let self, self.optionScrollZoomActive, !event.modifierFlags.contains(.option) {
                self.endOptionScrollZoomIfActive()
            }
            return event
        }
        installOptionScrollZoomLifecycleObservers()
    }

    func applyWindowAspectLock(width: CGFloat, height: CGFloat, minWidth: CGFloat, minHeight: CGFloat) {
        runOnMain {
            guard width > 0, height > 0, let win = self.primaryWindow else { return }
            win.styleMask.insert([.resizable])
            let safeMinW = max(120, minWidth)
            let safeMinH = max(120, minHeight)
            win.contentMinSize = NSSize(width: safeMinW, height: safeMinH)
            win.contentAspectRatio = NSSize(width: width, height: height)

            let screen = self.resolvedTargetScreen()
                ?? win.screen ?? NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let titleOverhead = self.estimatedTitleOverhead(win)
            let maxW = max(safeMinW, floor(visible.width - 16))
            let maxH = max(safeMinH, floor(visible.height - titleOverhead - 16))

            let curRect = win.contentLayoutRect
            let cur = (curRect.width > 1 && curRect.height > 1) ? curRect.size : win.frame.size
            var newW: CGFloat
            var newH: CGFloat
            if height >= width {
                newH = min(max(cur.height, safeMinH), maxH)
                newW = round(newH * (width / height))
                if newW > maxW {
                    newW = maxW
                    newH = round(newW * (height / width))
                }
            } else {
                newW = min(max(cur.width, safeMinW), maxW)
                newH = round(newW * (height / width))
                if newH > maxH {
                    newH = maxH
                    newW = round(newH * (width / height))
                }
            }
            win.setContentSize(NSSize(width: max(safeMinW, newW), height: max(safeMinH, newH)))
            self.clampWindow(win, to: visible, centerIfOutside: true)
        }
    }

    func clearWindowAspectLock(minWidth: CGFloat, minHeight: CGFloat) {
        runOnMain {
            guard let win = self.primaryWindow else { return }
            win.styleMask.insert([.resizable])
            win.contentAspectRatio = .zero
            win.resizeIncrements = NSSize(width: 1, height: 1)
            win.contentMinSize = NSSize(width: max(120, minWidth), height: max(120, minHeight))
        }
    }

    func placeWindowOnTargetScreenIfNeeded() {
        runOnMain {
            guard let target = self.resolvedTargetScreen(),
                  let win = self.primaryWindow else { return }
            self.configureWindowIfNeeded(win)
            self.centerAndClampWindow(win, on: target)
        }
    }
}

private extension AKPlugin {
    func handleOptionScrollWheelEvent(
        _ event: NSEvent,
        onZoom: (CGFloat, CGFloat, CGFloat, Bool) -> Bool
    ) -> NSEvent? {
        let relevantFlags = event.modifierFlags.intersection([.option, .command, .control])
        guard relevantFlags == .option else {
            endOptionScrollZoomIfActive()
            return event
        }
        if !event.momentumPhase.isEmpty || event.phase == .ended || event.phase == .cancelled {
            if optionScrollZoomActive {
                endOptionScrollZoomIfActive()
                return nil
            }
            return event
        }
        guard let normalizedPoint = normalizedPrimaryContentPoint(for: event) else {
            return event
        }

        var deltaY = event.scrollingDeltaY
        let isPrecise = event.hasPreciseScrollingDeltas
        if !isPrecise && event.isDirectionInvertedFromDevice {
            deltaY = -deltaY
        }
        if abs(deltaY) < 0.0001 {
            return optionScrollZoomActive ? nil : event
        }

        if onZoom(normalizedPoint.x, normalizedPoint.y, deltaY, isPrecise) {
            optionScrollZoomActive = true
            return nil
        }
        return event
    }

    func normalizedPrimaryContentPoint(for event: NSEvent) -> CGPoint? {
        guard let primary = primaryWindow, primary.isVisible, !primary.isMiniaturized else {
            return nil
        }
        let pointInWindow: NSPoint
        if let eventWindow = event.window {
            guard eventWindow === primary else { return nil }
            pointInWindow = event.locationInWindow
        } else {
            pointInWindow = primary.convertPoint(fromScreen: event.locationInWindow)
        }
        if isPointInTrafficLightArea(pointInWindow, window: primary) {
            return nil
        }

        let refRect: NSRect
        if let contentView = primary.contentView,
           contentView.frame.width >= 1,
           contentView.frame.height >= 1 {
            refRect = contentView.frame
        } else if primary.contentLayoutRect.width >= 1 && primary.contentLayoutRect.height >= 1 {
            refRect = primary.contentLayoutRect
        } else {
            refRect = NSRect(origin: .zero, size: primary.frame.size)
        }
        guard refRect.width >= 1, refRect.height >= 1, refRect.contains(pointInWindow) else {
            return nil
        }
        let normalizedX = (pointInWindow.x - refRect.minX) / refRect.width
        let normalizedY = (refRect.maxY - pointInWindow.y) / refRect.height
        return CGPoint(x: normalizedX, y: normalizedY)
    }

    func isPointInTrafficLightArea(_ pointInWindow: NSPoint, window: NSWindow) -> Bool {
        guard hideTitleBarSetting else { return false }
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .fullScreenButton]
        for type in buttonTypes {
            if let button = window.standardWindowButton(type) {
                let localPoint = button.convert(pointInWindow, from: nil)
                if button.bounds.contains(localPoint) {
                    return true
                }
            }
        }
        return false
    }

    func installOptionScrollZoomLifecycleObservers() {
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notif in
                guard let self else { return }
                if let win = notif.object as? NSWindow, win !== self.primaryWindow {
                    return
                }
                self.endOptionScrollZoomIfActive()
            }
        }
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.endOptionScrollZoomIfActive()
            }
        }
    }

    func endOptionScrollZoomIfActive() {
        guard optionScrollZoomActive else { return }
        optionScrollZoomActive = false
        optionScrollZoomEndHandler?()
    }

    var primaryWindow: NSWindow? {
        NSApplication.shared.windows.first(where: { isMainAppWindow($0) })
            ?? NSApplication.shared.windows.first
    }

    func isMainAppWindow(_ win: NSWindow) -> Bool {
        let className = NSStringFromClass(type(of: win))
        if className.contains("Menu") || className.contains("StatusBar") || className.contains("Tooltip") {
            return false
        }
        return win.canBecomeMain && !win.isSheet
    }

    func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    func resolvedTargetScreen() -> NSScreen? {
        let env = ProcessInfo.processInfo.environment["PLAYCOVER_TARGET_SCREEN"]?.lowercased() ?? ""
        guard env == "sidecar" || env == "secondary" else { return nil }
        return NSScreen.screens.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("Sidecar")
        }) ?? (NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen.main)
    }

    func configureAllWindows() {
        for win in NSApplication.shared.windows {
            configureWindowIfNeeded(win)
        }
    }

    func configureWindowIfNeeded(_ win: NSWindow) {
        guard isMainAppWindow(win) else { return }
        applyAppearanceRules(win)
        updateGlobalBackButton(for: win)

        if !configuredWindows.contains(win) {
            configuredWindows.add(win)
            applyInitialSizing(win)
        } else if !verifiedTargetWindows.contains(win),
                  win.isVisible,
                  let target = resolvedTargetScreen() {
            verifiedTargetWindows.add(win)
            if !target.visibleFrame.intersects(win.frame) {
                centerAndClampWindow(win, on: target)
            }
        }
    }

    func applyAppearanceRules(_ win: NSWindow) {
        if resolutionSetting == 6 || resolutionSetting == 7 {
            win.styleMask.insert([.resizable])
        } else {
            win.styleMask.remove(.resizable)
        }
        win.collectionBehavior = [.fullScreenPrimary, .managed, .participatesInCycle]
        win.isMovable = true
        win.isMovableByWindowBackground = true

        if hideTitleBarSetting {
            win.styleMask.insert([.fullSizeContentView])
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.toolbar = nil
            win.title = ""
        }
        if floatingWindowSetting {
            win.level = .floating
        }
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applyInitialSizing(_ win: NSWindow) {
        let env = ProcessInfo.processInfo.environment
        let isAutomatedRun = env["PLAYTOOLS_AUTOMATION"] == "1"
            || !(env["PLAYCOVER_TARGET_SCREEN"] ?? "").isEmpty

        let useTemporaryWideDuoDefault = Self.temporaryDefaultWideDuoWindow
            && resolutionSetting == 7
            && (layoutInfo.isAdaptive || sdkShiftSetting)

        if !isAutomatedRun,
           (resolutionSetting == 7 || resolutionSetting == 6),
           let saved = loadSavedWindowFrame(),
           saved.resolution == resolutionSetting,
           !(useTemporaryWideDuoDefault && (saved.frame.width <= saved.frame.height || saved.frame.width < 600)) {
            let target = screenForSavedFrame(saved.frame)
                ?? win.screen ?? NSScreen.main ?? NSScreen.screens.first
            let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let titleOverhead = estimatedTitleOverhead(win)
            let maxW = max(240, floor(visible.width - 24))
            let maxH = max(240, floor(visible.height - titleOverhead - 20))

            isRestoringSavedFrame = true
            defer { isRestoringSavedFrame = false }

            if resolutionSetting == 7 && (layoutInfo.isAdaptive || sdkShiftSetting) {
                win.resizeIncrements = NSSize(width: 1, height: 1)
                let minW: CGFloat = (layoutIdiomSetting == 1 || (layoutIdiomSetting == 3 && layoutInfo.families.contains(1))) ? 320 : 360
                let minH: CGFloat = (layoutIdiomSetting == 1 || (layoutIdiomSetting == 3 && layoutInfo.families.contains(1))) ? 520 : 540
                win.contentMinSize = NSSize(width: minW, height: minH)
                let targetW = min(max(saved.frame.width, minW), visible.width)
                let targetH = min(max(saved.frame.height, minH + titleOverhead), visible.height)
                var clamped = NSRect(origin: saved.frame.origin, size: NSSize(width: targetW, height: targetH))
                clamped.origin.x = max(visible.minX, min(clamped.origin.x, visible.maxX - clamped.width))
                clamped.origin.y = max(visible.minY, min(clamped.origin.y, visible.maxY - clamped.height))
                win.setFrame(clamped, display: true)
                return
            } else {
                let aspect: (width: CGFloat, height: CGFloat, minW: CGFloat, minH: CGFloat)
                if resolutionSetting == 7 {
                    aspect = resolvedNonAdaptiveAspect()
                } else if let ar = aspectRatioSetting, ar.width > 0, ar.height > 0 {
                    aspect = (ar.width, ar.height, 240, 240)
                } else {
                    aspect = layoutInfo.recommendedAspect
                }
                win.contentMinSize = NSSize(width: aspect.minW, height: aspect.minH)
                win.contentAspectRatio = NSSize(width: aspect.width, height: aspect.height)
                let savedContentH = max(aspect.minH, saved.frame.height - titleOverhead)
                var targetH = min(savedContentH, maxH)
                var targetW = round(targetH * (aspect.width / aspect.height))
                if targetW > maxW {
                    targetW = maxW
                    targetH = round(targetW * (aspect.height / aspect.width))
                }
                win.setContentSize(NSSize(width: max(aspect.minW, targetW), height: max(aspect.minH, targetH)))
                let updated = win.frame
                let ox = max(visible.minX, min(saved.frame.origin.x, visible.maxX - updated.width))
                let oy = max(visible.minY, min(saved.frame.origin.y, visible.maxY - updated.height))
                win.setFrameOrigin(NSPoint(x: ox, y: oy))
                return
            }
        }

        let target = resolvedTargetScreen() ?? win.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        if resolutionSetting == 7 {
            let titleOverhead = estimatedTitleOverhead(win)
            let maxW = max(240, floor(visible.width - 24))
            let maxH = max(240, floor(visible.height - titleOverhead - 20))

            if layoutInfo.isAdaptive || sdkShiftSetting {
                win.resizeIncrements = NSSize(width: 1, height: 1)
                if layoutIdiomSetting == 1 || (layoutIdiomSetting == 3 && layoutInfo.families.contains(1)) {
                    win.contentMinSize = NSSize(width: 320, height: 520)
                    if Self.temporaryDefaultWideDuoWindow {
                        let initW = max(640, min(1000, round(visible.width * 0.78), maxW))
                        var initH = max(520, min(760, round(visible.height * 0.82), maxH))
                        if initW >= 600 && initH >= initW {
                            initH = max(520, initW - 80)
                        }
                        win.setContentSize(NSSize(width: initW, height: initH))
                    } else {
                        let initW = max(320, min(420, maxW))
                        let initH = max(520, min(760, round(visible.height * 0.82), maxH))
                        win.setContentSize(NSSize(width: initW, height: initH))
                    }
                } else {
                    win.contentMinSize = NSSize(width: 360, height: 540)
                    let initW = max(360, min(920, round(visible.width * 0.68), maxW))
                    let initH = max(540, min(780, round(visible.height * 0.82), maxH))
                    win.setContentSize(NSSize(width: initW, height: initH))
                }
            } else {
                let aspect = resolvedNonAdaptiveAspect()
                win.contentMinSize = NSSize(width: aspect.minW, height: aspect.minH)
                win.contentAspectRatio = NSSize(width: aspect.width, height: aspect.height)
                var targetH = floor(visible.height * 0.82)
                if aspect.height > aspect.width {
                    targetH = min(targetH, 800)
                }
                targetH = min(targetH, maxH)
                var targetW = round(targetH * (aspect.width / aspect.height))
                if targetW > maxW {
                    targetW = maxW
                    targetH = round(targetW * (aspect.height / aspect.width))
                }
                win.setContentSize(NSSize(width: max(aspect.minW, targetW), height: max(aspect.minH, targetH)))
            }
            if let target = target {
                centerAndClampWindow(win, on: target)
            }
        } else {
            if resolutionSetting == 6, let aspectRatio = aspectRatioSetting {
                win.contentAspectRatio = aspectRatio
            }
            if let target = resolvedTargetScreen() {
                centerAndClampWindow(win, on: target)
            }
        }

        if win.isVisible, let target = resolvedTargetScreen(), target.visibleFrame.intersects(win.frame) {
            verifiedTargetWindows.add(win)
        }
    }

    func saveWindowFrameIfAppropriate(_ win: NSWindow) {
        let env = ProcessInfo.processInfo.environment
        guard !isRestoringSavedFrame,
              configuredWindows.contains(win),
              isMainAppWindow(win),
              win.isVisible,
              !win.styleMask.contains(.fullScreen),
              env["PLAYTOOLS_AUTOMATION"] != "1",
              (env["PLAYCOVER_TARGET_SCREEN"] ?? "").isEmpty,
              resolvedTargetScreen() == nil else {
            return
        }
        let frame = win.frame
        guard frame.width >= 200, frame.height >= 200 else { return }
        let payload: [String: Any] = [
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "width": Double(frame.size.width),
            "height": Double(frame.size.height),
            "resolution": resolutionSetting,
            "layoutIdiom": layoutIdiomSetting
        ]
        UserDefaults.standard.set(payload, forKey: Self.savedFrameDefaultsKey)
    }

    func loadSavedWindowFrame() -> (frame: NSRect, resolution: Int)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.savedFrameDefaultsKey),
              let x = (dict["x"] as? NSNumber)?.doubleValue,
              let y = (dict["y"] as? NSNumber)?.doubleValue,
              let w = (dict["width"] as? NSNumber)?.doubleValue,
              let h = (dict["height"] as? NSNumber)?.doubleValue,
              let res = (dict["resolution"] as? NSNumber)?.intValue,
              w >= 200, h >= 200 else {
            return nil
        }
        return (NSRect(x: x, y: y, width: w, height: h), res)
    }

    func screenForSavedFrame(_ frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let containing = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }
        return NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(frame)
            let ib = b.frame.intersection(frame)
            return (ia.width * ia.height) < (ib.width * ib.height)
        }
    }

    func resolvedNonAdaptiveAspect() -> (width: CGFloat, height: CGFloat, minW: CGFloat, minH: CGFloat) {
        if let data = Self.akAppSettingsData,
           (data.resizableAspectRatioType ?? 0) != 0,
           let w = data.resizableAspectRatioWidth,
           let h = data.resizableAspectRatioHeight,
           w > 0, h > 0 {
            let ratioW = CGFloat(w)
            let ratioH = CGFloat(h)
            if w == 9 && h == 16 { return (9, 16, 270, 480) }
            if w == 16 && h == 9 { return (16, 9, 480, 270) }
            if w == 3 && h == 4 { return (3, 4, 360, 480) }
            if w == 4 && h == 3 { return (4, 3, 480, 360) }
            let minW = ratioW >= ratioH ? round(270 * ratioW / ratioH) : 270
            let minH = ratioH > ratioW ? round(270 * ratioH / ratioW) : 270
            return (ratioW, ratioH, minW, minH)
        }
        return layoutInfo.recommendedAspect
    }

    func estimatedTitleOverhead(_ win: NSWindow) -> CGFloat {
        if hideTitleBarSetting || win.styleMask.contains(.fullSizeContentView) {
            return 0
        }
        let rectH = win.contentLayoutRect.height
        if rectH > 1 && win.frame.height >= rectH {
            return min(64, win.frame.height - rectH)
        }
        return 28
    }

    func centerAndClampWindow(_ win: NSWindow, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let frame = win.frame
        if frame.width > visible.width || frame.height > visible.height {
            let titleOverhead = estimatedTitleOverhead(win)
            let maxW = max(240, floor(visible.width - 16))
            let maxH = max(240, floor(visible.height - titleOverhead - 16))
            let curContent = win.contentLayoutRect.width > 1 ? win.contentLayoutRect.size : frame.size
            var newW = min(curContent.width, maxW)
            var newH = min(curContent.height, maxH)
            if win.contentAspectRatio.width > 0 && win.contentAspectRatio.height > 0 {
                let ratio = win.contentAspectRatio.width / win.contentAspectRatio.height
                newH = min(maxH, round(newW / ratio))
                newW = round(newH * ratio)
            }
            win.setContentSize(NSSize(width: newW, height: newH))
        }
        let updated = win.frame
        var x = round(visible.origin.x + (visible.width - updated.width) / 2.0)
        var y = round(visible.origin.y + (visible.height - updated.height) / 2.0)
        x = max(visible.minX, min(x, visible.maxX - updated.width))
        y = max(visible.minY, min(y, visible.maxY - updated.height))
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func clampWindow(_ win: NSWindow, to visible: NSRect, centerIfOutside: Bool) {
        let frame = win.frame
        if centerIfOutside && !visible.intersects(frame) {
            var x = round(visible.origin.x + (visible.width - frame.width) / 2.0)
            var y = round(visible.origin.y + (visible.height - frame.height) / 2.0)
            x = max(visible.minX, min(x, visible.maxX - frame.width))
            y = max(visible.minY, min(y, visible.maxY - frame.height))
            win.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        let x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        let y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct AKGlobalBackSettingsData: Codable {
    var titlebarBackEnabled: Bool = true
    var onlyWhenNoSidebarBackButton: Bool = true
    var includeTopCloseButtons: Bool = true
    var shortcutEnabled: Bool = true
    var shortcutKind: String = "mouse"
    var shortcutKeyCode: UInt16 = 0
    var shortcutButtonNumber: Int = 3
    var shortcutModifiersRaw: UInt = 0
    var shortcutDisplayName: String = "Mouse Button 4"
    var titlebarHomeEnabled: Bool = true
    var homeShortcutEnabled: Bool = true
    var homeShortcutKind: String = "none"
    var homeShortcutKeyCode: UInt16 = 0
    var homeShortcutButtonNumber: Int = -1
    var homeShortcutModifiersRaw: UInt = 0
    var homeShortcutDisplayName: String = ""

    static var defaultSettings: AKGlobalBackSettingsData {
        AKGlobalBackSettingsData()
    }

    static var configURL: URL {
        URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("GlobalBackSettings.plist")
    }

    static func load() -> AKGlobalBackSettingsData {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? PropertyListDecoder().decode(AKGlobalBackSettingsData.self, from: data) else {
            return .defaultSettings
        }
        return decoded
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AKGlobalBackSettingsData.defaultSettings
        titlebarBackEnabled = try c.decodeIfPresent(Bool.self, forKey: .titlebarBackEnabled) ?? d.titlebarBackEnabled
        onlyWhenNoSidebarBackButton = try c.decodeIfPresent(Bool.self, forKey: .onlyWhenNoSidebarBackButton) ?? d.onlyWhenNoSidebarBackButton
        includeTopCloseButtons = try c.decodeIfPresent(Bool.self, forKey: .includeTopCloseButtons) ?? d.includeTopCloseButtons
        shortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .shortcutEnabled) ?? d.shortcutEnabled
        shortcutKind = try c.decodeIfPresent(String.self, forKey: .shortcutKind) ?? d.shortcutKind
        shortcutKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .shortcutKeyCode) ?? d.shortcutKeyCode
        shortcutButtonNumber = try c.decodeIfPresent(Int.self, forKey: .shortcutButtonNumber) ?? d.shortcutButtonNumber
        shortcutModifiersRaw = try c.decodeIfPresent(UInt.self, forKey: .shortcutModifiersRaw) ?? d.shortcutModifiersRaw
        shortcutDisplayName = try c.decodeIfPresent(String.self, forKey: .shortcutDisplayName) ?? d.shortcutDisplayName
        titlebarHomeEnabled = try c.decodeIfPresent(Bool.self, forKey: .titlebarHomeEnabled) ?? d.titlebarHomeEnabled
        homeShortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .homeShortcutEnabled) ?? d.homeShortcutEnabled
        homeShortcutKind = try c.decodeIfPresent(String.self, forKey: .homeShortcutKind) ?? d.homeShortcutKind
        homeShortcutKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .homeShortcutKeyCode) ?? d.homeShortcutKeyCode
        homeShortcutButtonNumber = try c.decodeIfPresent(Int.self, forKey: .homeShortcutButtonNumber) ?? d.homeShortcutButtonNumber
        homeShortcutModifiersRaw = try c.decodeIfPresent(UInt.self, forKey: .homeShortcutModifiersRaw) ?? d.homeShortcutModifiersRaw
        homeShortcutDisplayName = try c.decodeIfPresent(String.self, forKey: .homeShortcutDisplayName) ?? d.homeShortcutDisplayName
    }

    var normalizedModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: shortcutModifiersRaw).intersection([.command, .option, .control, .shift])
    }

    var homeNormalizedModifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: homeShortcutModifiersRaw).intersection([.command, .option, .control, .shift])
    }
}

private final class AKGlobalBackTitlebarButton: NSButton {
    var usesPillBackdrop = false {
        didSet {
            if usesPillBackdrop != oldValue {
                updateAppearance()
            }
        }
    }

    private var isHovered = false {
        didSet {
            if isHovered != oldValue {
                updateAppearance()
            }
        }
    }

    private var hoverTrackingArea: NSTrackingArea?

    init(
        frame frameRect: NSRect,
        symbolName: String = "chevron.backward",
        accessibilityDescription: String = "Back"
    ) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        title = ""
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) {
            sym.isTemplate = true
            image = sym
        }
        contentTintColor = .labelColor
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        guard let layer else { return }
        if usesPillBackdrop {
            layer.cornerRadius = 6
            layer.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(isHovered ? 0.92 : 0.72).cgColor
            layer.borderWidth = 0.5
            layer.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        } else {
            layer.cornerRadius = 5
            layer.backgroundColor = isHovered
                ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }
}

extension AKPlugin {
    @objc func setupGlobalBackIntegration(
        queryState: @escaping (Bool) -> Int,
        performBack: @escaping (Bool) -> Bool
    ) {
        runOnMain {
            self.globalBackQueryState = queryState
            self.globalBackPerformBack = performBack
            self.globalBackSettings = AKGlobalBackSettingsData.load()
            self.installGlobalBackMonitorIfNeeded()
            self.refreshGlobalBackUI()
        }
    }

    @objc func setupGlobalHomeIntegration(
        queryHome: @escaping () -> Bool,
        performHome: @escaping () -> Bool
    ) {
        runOnMain {
            self.globalHomeQueryState = queryHome
            self.globalHomePerformHome = performHome
            self.installGlobalBackMonitorIfNeeded()
            self.refreshGlobalBackUI()
        }
    }

    @objc func refreshGlobalBackUI() {
        let work = { [weak self] in
            guard let self else { return }
            for win in NSApplication.shared.windows where self.isMainAppWindow(win) {
                self.updateGlobalBackButton(for: win)
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

private extension AKPlugin {

    func scheduleDebouncedGlobalBackRefresh() {
        globalBackPostClickWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.globalBackPostClickWorkItem = nil
            self.refreshGlobalBackUI()
        }
        globalBackPostClickWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    func reloadGlobalBackSettingsAndRefresh() {
        globalBackSettings = AKGlobalBackSettingsData.load()
        for win in NSApplication.shared.windows where isMainAppWindow(win) {
            updateGlobalBackButton(for: win)
        }
    }

    func shortcutTooltip(base: String, enabled: Bool, kind: String, displayName: String) -> String {
        if enabled, kind != "none", !displayName.isEmpty {
            return "\(base) (\(displayName))"
        }
        return base
    }

    func updateGlobalBackButton(for win: NSWindow) {
        guard isMainAppWindow(win) else { return }
        let isPrimary = (win === primaryWindow)
        let showBack: Bool
        let showHome: Bool
        if isPrimary {
            if let query = globalBackQueryState {
                let state = query(globalBackSettings.includeTopCloseButtons)
                let hasBack = (state & 1) != 0
                let hasSidebarBack = (state & 2) != 0
                showBack = globalBackSettings.titlebarBackEnabled
                    && hasBack
                    && (!globalBackSettings.onlyWhenNoSidebarBackButton || !hasSidebarBack)
            } else {
                showBack = false
            }
            if let queryHome = globalHomeQueryState {
                showHome = globalBackSettings.titlebarHomeEnabled && queryHome()
            } else {
                showHome = false
            }
        } else {
            showBack = false
            showHome = false
        }

        if showHome || showBack {
            let accessoryVC: NSTitlebarAccessoryViewController
            let backBtn: AKGlobalBackTitlebarButton
            let homeBtn: AKGlobalBackTitlebarButton
            if let existingVC = globalBackAccessoryByWindow.object(forKey: win),
               let existingBack = globalBackButtonByWindow.object(forKey: win),
               let existingHome = globalHomeButtonByWindow.object(forKey: win) {
                accessoryVC = existingVC
                backBtn = existingBack
                homeBtn = existingHome
            } else {
                let vc = NSTitlebarAccessoryViewController()
                vc.layoutAttribute = .trailing

                let hBtn = AKGlobalBackTitlebarButton(
                    frame: NSRect(x: 0, y: 0, width: 28, height: 22),
                    symbolName: "house",
                    accessibilityDescription: "Home"
                )
                hBtn.translatesAutoresizingMaskIntoConstraints = false
                hBtn.target = self
                hBtn.action = #selector(handleTitlebarGlobalHomeClick(_:))

                let bBtn = AKGlobalBackTitlebarButton(
                    frame: NSRect(x: 0, y: 0, width: 28, height: 22),
                    symbolName: "chevron.backward",
                    accessibilityDescription: "Back"
                )
                bBtn.translatesAutoresizingMaskIntoConstraints = false
                bBtn.target = self
                bBtn.action = #selector(handleTitlebarGlobalBackClick(_:))

                NSLayoutConstraint.activate([
                    hBtn.widthAnchor.constraint(equalToConstant: 28),
                    hBtn.heightAnchor.constraint(equalToConstant: 22),
                    bBtn.widthAnchor.constraint(equalToConstant: 28),
                    bBtn.heightAnchor.constraint(equalToConstant: 22)
                ])

                let stack = NSStackView(views: [hBtn, bBtn])
                stack.translatesAutoresizingMaskIntoConstraints = false
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = 4
                stack.detachesHiddenViews = true
                stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)

                let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 26))
                container.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    stack.topAnchor.constraint(equalTo: container.topAnchor),
                    stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                ])

                vc.view = container
                globalBackAccessoryByWindow.setObject(vc, forKey: win)
                globalBackStackByWindow.setObject(stack, forKey: win)
                globalHomeButtonByWindow.setObject(hBtn, forKey: win)
                globalBackButtonByWindow.setObject(bBtn, forKey: win)
                accessoryVC = vc
                homeBtn = hBtn
                backBtn = bBtn
            }

            homeBtn.isHidden = !showHome
            backBtn.isHidden = !showBack
            homeBtn.usesPillBackdrop = hideTitleBarSetting
            backBtn.usesPillBackdrop = hideTitleBarSetting
            homeBtn.toolTip = shortcutTooltip(
                base: "回到首页",
                enabled: globalBackSettings.homeShortcutEnabled,
                kind: globalBackSettings.homeShortcutKind,
                displayName: globalBackSettings.homeShortcutDisplayName
            )
            backBtn.toolTip = shortcutTooltip(
                base: "返回",
                enabled: globalBackSettings.shortcutEnabled,
                kind: globalBackSettings.shortcutKind,
                displayName: globalBackSettings.shortcutDisplayName
            )
            let targetWidth: CGFloat = (showHome && showBack) ? 64 : 34
            if abs(accessoryVC.view.frame.size.width - targetWidth) > 0.5 {
                accessoryVC.view.setFrameSize(NSSize(width: targetWidth, height: 26))
            }
            if !win.titlebarAccessoryViewControllers.contains(where: { $0 === accessoryVC }) {
                win.addTitlebarAccessoryViewController(accessoryVC)
            }
        } else if let existingVC = globalBackAccessoryByWindow.object(forKey: win),
                  let idx = win.titlebarAccessoryViewControllers.firstIndex(where: { $0 === existingVC }) {
            win.removeTitlebarAccessoryViewController(at: idx)
        }
    }

    @objc func handleTitlebarGlobalBackClick(_ sender: Any?) {
        _ = globalBackPerformBack?(globalBackSettings.includeTopCloseButtons)
        DispatchQueue.main.async { [weak self] in
            self?.refreshGlobalBackUI()
        }
    }

    @objc func handleTitlebarGlobalHomeClick(_ sender: Any?) {
        _ = globalHomePerformHome?()
        DispatchQueue.main.async { [weak self] in
            self?.refreshGlobalBackUI()
        }
    }

    func isPointInGlobalBackButton(_ pointInWindow: NSPoint, window: NSWindow) -> Bool {
        for table in [globalBackButtonByWindow, globalHomeButtonByWindow] {
            if let button = table.object(forKey: window),
               button.window === window,
               !button.isHidden {
                let localPoint = button.convert(pointInWindow, from: nil)
                if button.bounds.contains(localPoint) {
                    return true
                }
            }
        }
        return false
    }

    func installGlobalBackMonitorIfNeeded() {
        guard !globalBackMonitorInstalled else { return }
        globalBackMonitorInstalled = true
        NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleGlobalBackMonitorEvent(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            if self.globalBackSettings.titlebarBackEnabled
                || self.globalBackSettings.titlebarHomeEnabled
                || self.globalBackSettings.shortcutEnabled
                || self.globalBackSettings.homeShortcutEnabled,
               let win = event.window,
               win === self.primaryWindow,
               win.isVisible,
               !self.isPointInGlobalBackButton(event.locationInWindow, window: win) {
                self.scheduleDebouncedGlobalBackRefresh()
            }
            return event
        }
    }

    func matchesShortcutEvent(
        _ event: NSEvent,
        kind: String,
        keyCode: UInt16,
        buttonNumber: Int,
        targetFlags: NSEvent.ModifierFlags,
        win: NSWindow
    ) -> Bool {
        let relevantFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch kind {
        case "keyboard":
            return event.type == .keyDown
                && !event.isARepeat
                && event.keyCode == keyCode
                && relevantFlags == targetFlags
        case "mouse":
            guard event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown,
                  event.buttonNumber == buttonNumber,
                  relevantFlags == targetFlags else {
                return false
            }
            let pt = event.locationInWindow
            if isPointInTrafficLightArea(pt, window: win) || isPointInGlobalBackButton(pt, window: win) {
                return false
            }
            if buttonNumber == 0 && relevantFlags.isEmpty && pt.y > win.contentLayoutRect.maxY {
                return false
            }
            return true
        default:
            return false
        }
    }

    func handleGlobalBackMonitorEvent(_ event: NSEvent) -> NSEvent? {
        guard let win = event.window,
              win === primaryWindow,
              win.isVisible else {
            return event
        }
        let relevantFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let includeClose = globalBackSettings.includeTopCloseButtons

        if globalBackSettings.shortcutEnabled,
           globalBackSettings.shortcutKind != "none",
           matchesShortcutEvent(
               event,
               kind: globalBackSettings.shortcutKind,
               keyCode: globalBackSettings.shortcutKeyCode,
               buttonNumber: globalBackSettings.shortcutButtonNumber,
               targetFlags: globalBackSettings.normalizedModifierFlags,
               win: win
           ),
           let query = globalBackQueryState {
            let state = query(includeClose)
            let hasBack = (state & 1) != 0
            let isTextInput = (state & 4) != 0
            if globalBackSettings.shortcutKind == "keyboard",
               isTextInput && relevantFlags.isEmpty && event.keyCode != 53 {
                return event
            }
            if hasBack {
                let handled = globalBackPerformBack?(includeClose) ?? false
                DispatchQueue.main.async { [weak self] in
                    self?.refreshGlobalBackUI()
                }
                if handled {
                    return nil
                }
            }
        }

        if globalBackSettings.homeShortcutEnabled,
           globalBackSettings.homeShortcutKind != "none",
           matchesShortcutEvent(
               event,
               kind: globalBackSettings.homeShortcutKind,
               keyCode: globalBackSettings.homeShortcutKeyCode,
               buttonNumber: globalBackSettings.homeShortcutButtonNumber,
               targetFlags: globalBackSettings.homeNormalizedModifierFlags,
               win: win
           ),
           let queryHome = globalHomeQueryState {
            let state = globalBackQueryState?(false) ?? 0
            let isTextInput = (state & 4) != 0
            if globalBackSettings.homeShortcutKind == "keyboard",
               isTextInput && relevantFlags.isEmpty && event.keyCode != 53 {
                return event
            }
            if queryHome() {
                let handled = globalHomePerformHome?() ?? false
                DispatchQueue.main.async { [weak self] in
                    self?.refreshGlobalBackUI()
                }
                if handled {
                    return nil
                }
            }
        }

        return event
    }
}
