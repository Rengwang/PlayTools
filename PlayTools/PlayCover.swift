//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import UIKit

public class PlayCover: NSObject {

    static let shared = PlayCover()
    var menuController: MenuController?

    @objc static public func launch() {
        quitWhenClose()
        AKInterface.initialize()
        initializeGlobalBackIntegration()
        UserPluginLoader.initialize()
        PlayScreen.shared.initialize()
        PlayInput.shared.initialize()
        DiscordIPC.shared.initialize()
        PlayInfo.installPowerStateHooksIfNeeded()
        PlayMemoryReclaimer.shared.initialize()
        PlayToolsSelfTest.startIfRequested()

        if PlaySettings.shared.rootWorkDir {
            // Change the working directory to / just like iOS
            FileManager.default.changeCurrentDirectoryPath("/")
        }

        if PlaySettings.shared.displayRotation != 0 {
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.5, execute: {
                let rotateCommand = UIKeyCommand(
                    title: "Keep Rotation Command",
                    image: nil,
                    action: #selector(UIApplication.rotateView(_:)),
                    input: "",
                    modifierFlags: [],
                    propertyList: ["rotationIndex": PlaySettings.shared.displayRotation]
                )
                UIApplication.shared.sendAction(
                    #selector(UIApplication.rotateView(_:)),
                    to: UIApplication.shared,
                    from: rotateCommand,
                    for: nil
                )
            })
        }
    }

    @objc static public func initMenu(menu: NSObject) {
        guard let menuBuilder = menu as? UIMenuBuilder else { return }
        shared.menuController = MenuController(with: menuBuilder)
    }

    private static let terminationLock = NSLock()
    private static var quitWhenCloseInstalled = false
    private static var isTerminatingFromCloseOrApp = false

    private static func markTerminatingIfNotYet() -> Bool {
        terminationLock.lock()
        defer { terminationLock.unlock() }
        if isTerminatingFromCloseOrApp {
            return false
        }
        isTerminatingFromCloseOrApp = true
        return true
    }

    private static func markTerminating() {
        terminationLock.lock()
        isTerminatingFromCloseOrApp = true
        terminationLock.unlock()
    }

    static public func quitWhenClose() {
        terminationLock.lock()
        let alreadyInstalled = quitWhenCloseInstalled
        quitWhenCloseInstalled = true
        terminationLock.unlock()
        guard !alreadyInstalled else { return }

        // Observe NSApplicationWillTerminateNotification synchronously (queue: nil) so
        // termination via Cmd+Q / NSApplication.terminate marks the flag BEFORE AppKit's
        // _deallocHardCore -> _closeForTermination posts NSWindowWillCloseNotification.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSApplicationWillTerminateNotification"),
            object: nil,
            queue: nil
        ) { _ in
            markTerminating()
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { notif in
            guard PlayScreen.shared.nsWindow?.isEqual(notif.object) ?? false else { return }
            guard markTerminatingIfNotYet() else { return }
            pt_markAppTerminating()

            // Step 1: Resign active
            for scene in UIApplication.shared.connectedScenes {
                scene.delegate?.sceneWillResignActive?(scene)
                NotificationCenter.default.post(name: UIScene.willDeactivateNotification,
                                                object: scene)
            }
            UIApplication.shared.delegate?.applicationWillResignActive?(UIApplication.shared)
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                            object: UIApplication.shared)

            // Step 2: Enter background
            for scene in UIApplication.shared.connectedScenes {
                scene.delegate?.sceneDidEnterBackground?(scene)
                NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification,
                                                object: scene)
            }
            UIApplication.shared.delegate?.applicationDidEnterBackground?(UIApplication.shared)
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification,
                                            object: UIApplication.shared)

            // Step 2.5: End UIBackgroundTask
            // There is an expiration handler, but idk how to invoke it. Skip for now.

            // Step 3: Terminate
            for scene in UIApplication.shared.connectedScenes {
                scene.delegate?.sceneDidDisconnect?(scene)
                NotificationCenter.default.post(name: UIScene.didDisconnectNotification,
                                                object: scene)
            }
            UIApplication.shared.delegate?.applicationWillTerminate?(UIApplication.shared)
            // Some apps will freeze or crash when click close button if we send willTerminateNotification.
            // The developer documentation says this is a "may be called method", so it can be safely skipped.
            // https://developer.apple.com/documentation/uikit/uiapplicationdelegate/1623111-applicationwillterminate
            // swiftlint:disable:previous line_length
//            NotificationCenter.default.post(name: UIApplication.willTerminateNotification,
//                                            object: UIApplication.shared)
            DispatchQueue.main.async {
                AKInterface.shared?.terminateApplication()
            }

            // Step 3.5: End BGTask
            // BGTask typically runs in another process and is tricky to terminate.
            // It may run into infinite loops, end up silently heating the device up.
            // This actually happens for ToF. Hope future developers can solve this.
        }
    }

    static func delay(_ delay: Double, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: when, execute: closure)
    }

    static func activeUIWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow && !$0.isHidden }) {
                return keyWindow
            }
            if let visibleWindow = windowScene.windows.first(where: { !$0.isHidden && $0.alpha > 0.01 }) {
                return visibleWindow
            }
        }
        return nil
    }

    private static var globalBackRefreshPending = false
    private static var globalBackRefreshTrailingRequested = false
    private static var lastGlobalBackRefreshUptime: TimeInterval = 0
    private static let globalBackRefreshMinInterval: TimeInterval = 0.08

    static func scheduleCoalescedGlobalBackRefresh() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                scheduleCoalescedGlobalBackRefresh()
            }
            return
        }
        if globalBackRefreshPending {
            globalBackRefreshTrailingRequested = true
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastGlobalBackRefreshUptime
        let delay = (elapsed >= 0 && elapsed < globalBackRefreshMinInterval)
            ? (globalBackRefreshMinInterval - elapsed)
            : 0.0
        globalBackRefreshPending = true
        let fire: () -> Void = {
            globalBackRefreshPending = false
            let hadTrailing = globalBackRefreshTrailingRequested
            globalBackRefreshTrailingRequested = false
            lastGlobalBackRefreshUptime = ProcessInfo.processInfo.systemUptime
            AKInterface.shared?.refreshGlobalBackUI?()
            if hadTrailing {
                scheduleCoalescedGlobalBackRefresh()
            }
        }
        if delay > 0.001 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire)
        } else {
            DispatchQueue.main.async(execute: fire)
        }
    }

    static func initializeGlobalBackIntegration() {
        PTDuoSetGlobalBackRefreshHandler {
            PlayCover.scheduleCoalescedGlobalBackRefresh()
        }
        AKInterface.shared?.setupGlobalBackIntegration?(
            queryState: { includeTopClose in
                let win = PlayCover.activeUIWindow()
                var hasSidebarBack: ObjCBool = false
                let hasBack = PTDuoQueryGlobalBackStateForWindow(win, includeTopClose, &hasSidebarBack)
                let isTextInput = PTDuoWindowHasActiveTextInput(win)
                var bitmask = 0
                if hasBack { bitmask |= 1 }
                if hasSidebarBack.boolValue { bitmask |= 2 }
                if isTextInput { bitmask |= 4 }
                return bitmask
            },
            performBack: { includeTopClose in
                let win = PlayCover.activeUIWindow()
                return PTDuoPerformGlobalBackActionForWindow(win, includeTopClose)
            }
        )
        AKInterface.shared?.setupGlobalHomeIntegration?(
            queryHome: {
                PTDuoQueryGlobalHomeStateForWindow(PlayCover.activeUIWindow())
            },
            performHome: {
                PTDuoPerformGlobalHomeActionForWindow(PlayCover.activeUIWindow())
            }
        )
    }
}

@_silgen_name("proc_pid_rusage")
private func pt_proc_pid_rusage(_ pid: pid_t, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?) -> Int32

/// Reclaims idle decoded image caches, SQLite connections and freed malloc pages
/// after the app has remained hidden in the background or under memory pressure.
final class PlayMemoryReclaimer {
    static let shared = PlayMemoryReclaimer()

    private static let windowVisibilityDidChangeNotification = Notification.Name("PTWindowVisibilityDidChangeNotification")

    private var initialized = false
    private var isHidden = false
    private var didTrimCurrentHideCycle = false
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingReliefWorkItems: [DispatchWorkItem] = []
    private var lastWarningDate: Date?
    private let warningCooldown: TimeInterval = 60.0
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var footprintTimer: DispatchSourceTimer?

    private lazy var trimDelay: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["PLAYTOOLS_BACKGROUND_TRIM_DELAY"],
           let parsed = Double(raw), parsed >= 0.5 && parsed <= 120.0 {
            return parsed
        }
        return 10.0
    }()

    private lazy var memorySoftLimitBytes: UInt64 = {
        if let raw = ProcessInfo.processInfo.environment["PLAYTOOLS_MEMORY_SOFT_LIMIT_MB"],
           let mb = UInt64(raw), mb > 0 {
            return mb * 1024 * 1024
        }
        return UInt64(2) * 1024 * 1024 * 1024
    }()

    private var hasVisibleWindow: Bool {
        AKInterface.shared?.hasUnoccludedVisibleWindow
            ?? AKInterface.shared?.hasVisibleUnminiaturizedWindow
            ?? false
    }

    private var isPastWarningCooldown: Bool {
        guard let last = lastWarningDate else { return true }
        return Date().timeIntervalSince(last) >= warningCooldown
    }

    func initialize() {
        guard !initialized else { return }
        initialized = true
        guard ProcessInfo.processInfo.environment["PLAYTOOLS_DISABLE_BACKGROUND_TRIM"] != "1" else {
            return
        }

        let center = NotificationCenter.default
        let hideNames: [Notification.Name] = [
            Notification.Name("NSApplicationDidHideNotification"),
            UIApplication.didEnterBackgroundNotification
        ]
        for name in hideNames {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleDidHide()
            }
        }
        center.addObserver(
            forName: Notification.Name("NSWindowDidMiniaturizeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.hasVisibleWindow else { return }
            self.handleDidHide()
        }

        let activeNames: [Notification.Name] = [
            Notification.Name("NSApplicationDidUnhideNotification"),
            Notification.Name("NSApplicationDidBecomeActiveNotification"),
            Notification.Name("NSWindowDidDeminiaturizeNotification"),
            UIApplication.didBecomeActiveNotification
        ]
        for name in activeNames {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleDidBecomeVisibleOrActive()
            }
        }

        center.addObserver(
            forName: Self.windowVisibilityDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.hasVisibleWindow {
                self.handleDidBecomeVisibleOrActive()
            } else {
                self.handleDidHide()
            }
        }

        if PlaySettings.shared.memorySavingMode {
            installMemorySavingMonitors()
        }
    }

    private func installMemorySavingMonitors() {
        let utilityQueue = DispatchQueue.global(qos: .utility)

        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: utilityQueue
        )
        pressureSource.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.performL1Reclaim()
                self.performL2Reclaim(requireHidden: false)
            }
        }
        memoryPressureSource = pressureSource
        pressureSource.resume()

        let timer = DispatchSource.makeTimerSource(queue: utilityQueue)
        timer.schedule(deadline: .now() + 15.0, repeating: 15.0, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.checkMemoryFootprintIfNeeded()
        }
        footprintTimer = timer
        timer.resume()
    }

    private func checkMemoryFootprintIfNeeded() {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            pt_proc_pid_rusage(getpid(), RUSAGE_INFO_V6, UnsafeMutableRawPointer(ptr))
        }
        guard result == 0, info.ri_phys_footprint > memorySoftLimitBytes else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isPastWarningCooldown else { return }
            self.performL1Reclaim()
            self.performL2Reclaim(requireHidden: false)
        }
    }

    private func cancelAllPendingWorkItems() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        for item in pendingReliefWorkItems {
            item.cancel()
        }
        pendingReliefWorkItems.removeAll()
    }

    private func handleDidHide() {
        isHidden = true
        guard !didTrimCurrentHideCycle, pendingWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.performBackgroundTrimIfStillHidden()
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + trimDelay, execute: workItem)
    }

    private func handleDidBecomeVisibleOrActive() {
        isHidden = false
        didTrimCurrentHideCycle = false
        cancelAllPendingWorkItems()
    }

    private func performBackgroundTrimIfStillHidden() {
        pendingWorkItem = nil
        guard isHidden,
              !(AKInterface.shared?.isApplicationActive ?? false),
              !hasVisibleWindow else {
            return
        }
        didTrimCurrentHideCycle = true
        performL1Reclaim()
        performL2Reclaim(requireHidden: true)
    }

    private func performL1Reclaim() {
        PlayScreen.shared.clearTransientCachesOnHide()
        DispatchQueue.global(qos: .utility).async {
            PlayKeychainDB.shared.releaseIdleResources()
        }

        // Flush URLCache in-memory entries only while leaving disk cache intact.
        let savedMemoryCapacity = URLCache.shared.memoryCapacity
        if savedMemoryCapacity > 0 {
            URLCache.shared.memoryCapacity = 0
            URLCache.shared.memoryCapacity = savedMemoryCapacity
        }

        if let hooksCls = NSClassFromString("PTEfficiencyHooks") as? NSObject.Type {
            let trimSel = NSSelectorFromString("trimRegisteredNSCaches")
            if hooksCls.responds(to: trimSel) {
                _ = hooksCls.perform(trimSel)
            }
        }

        DispatchQueue.global(qos: .utility).async {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }

    private func performL2Reclaim(requireHidden: Bool) {
        guard isPastWarningCooldown else { return }
        lastWarningDate = Date()

        let performWarningSel = NSSelectorFromString("_performMemoryWarning")
        if UIApplication.shared.responds(to: performWarningSel) {
            UIApplication.shared.perform(performWarningSel)
        } else {
            NotificationCenter.default.post(
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: UIApplication.shared
            )
        }

        for item in pendingReliefWorkItems {
            item.cancel()
        }
        pendingReliefWorkItems.removeAll()

        for reliefDelay in [0.8, 3.0] {
            weak var weakItem: DispatchWorkItem?
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if let item = weakItem {
                    self.pendingReliefWorkItems.removeAll { $0 === item }
                    if item.isCancelled { return }
                }
                if requireHidden && (!self.isHidden || self.hasVisibleWindow) {
                    return
                }
                DispatchQueue.global(qos: .utility).async {
                    _ = malloc_zone_pressure_relief(nil, 0)
                }
            }
            weakItem = workItem
            pendingReliefWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + reliefDelay, execute: workItem)
        }
    }
}
