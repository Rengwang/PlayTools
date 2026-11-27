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

    static public func quitWhenClose() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { notif in
            if PlayScreen.shared.nsWindow?.isEqual(notif.object) ?? false {
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
//                NotificationCenter.default.post(name: UIApplication.willTerminateNotification,
//                                                object: UIApplication.shared)
                DispatchQueue.main.async(execute: AKInterface.shared!.terminateApplication)

                // Step 3.5: End BGTask
                // BGTask typically runs in another process and is tricky to terminate.
                // It may run into infinite loops, end up silently heating the device up.
                // This actually happens for ToF. Hope future developers can solve this.
            }
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

    static func initializeGlobalBackIntegration() {
        PTDuoSetGlobalBackRefreshHandler {
            DispatchQueue.main.async {
                AKInterface.shared?.refreshGlobalBackUI?()
            }
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

/// Reclaims idle decoded image caches, SQLite connections and freed malloc pages
/// after the app has remained hidden in the background.
final class PlayMemoryReclaimer {
    static let shared = PlayMemoryReclaimer()

    private var initialized = false
    private var isHidden = false
    private var didTrimCurrentHideCycle = false
    private var pendingWorkItem: DispatchWorkItem?

    private lazy var trimDelay: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["PLAYTOOLS_BACKGROUND_TRIM_DELAY"],
           let parsed = Double(raw), parsed >= 0.5 && parsed <= 120.0 {
            return parsed
        }
        return 10.0
    }()

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
            guard let self = self,
                  !(AKInterface.shared?.hasVisibleUnminiaturizedWindow ?? false) else { return }
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
    }

    private func handleDidHide() {
        isHidden = true
        guard !didTrimCurrentHideCycle else { return }
        pendingWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.performBackgroundTrimIfStillHidden()
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + trimDelay, execute: workItem)
    }

    private func handleDidBecomeVisibleOrActive() {
        isHidden = false
        didTrimCurrentHideCycle = false
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
    }

    private func performBackgroundTrimIfStillHidden() {
        pendingWorkItem = nil
        guard isHidden,
              !(AKInterface.shared?.isApplicationActive ?? false),
              !(AKInterface.shared?.hasVisibleUnminiaturizedWindow ?? false) else {
            return
        }
        didTrimCurrentHideCycle = true

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

        let performWarningSel = NSSelectorFromString("_performMemoryWarning")
        if UIApplication.shared.responds(to: performWarningSel) {
            UIApplication.shared.perform(performWarningSel)
        } else {
            NotificationCenter.default.post(
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: UIApplication.shared
            )
        }

        for reliefDelay in [0.8, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + reliefDelay) { [weak self] in
                guard let self = self,
                      self.isHidden,
                      !(AKInterface.shared?.hasVisibleUnminiaturizedWindow ?? false) else {
                    return
                }
                DispatchQueue.global(qos: .utility).async {
                    _ = malloc_zone_pressure_relief(nil, 0)
                }
            }
        }
    }
}
