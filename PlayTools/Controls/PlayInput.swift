import Foundation
import UIKit
import GameController

// This class is a coordinator (and module entrance), coordinating other concrete classes

class PlayInput {
    static let shared = PlayInput()

    static var touchQueue = DispatchQueue.init(label: "playcover.toucher",
                                               qos: .userInteractive,
                                               autoreleaseFrequency: .workItem)

    private var displayLink: CADisplayLink?
    private var isAppActive = true

    @objc func drainMainDispatchQueue() {
        _dispatch_main_queue_callback_4CF(nil)
    }

    func initialize() {
        if PlaySettings.shared.disableBuiltinMouse {
            simulateGCMouseDisconnect()
        }

        guard PlaySettings.shared.keymapping else {
            return
        }

        let centre = NotificationCenter.default
        let main = OperationQueue.main

        // Only run the CADisplayLink queue-drainer while keymapping is active,
        // at least one GCController is connected, and the app is foreground-active.
        for name in [
            NSNotification.Name.GCControllerDidConnect,
            NSNotification.Name.GCControllerDidDisconnect
        ] {
            centre.addObserver(forName: name, object: nil, queue: main) { [weak self] _ in
                self?.updateDisplayLinkState()
            }
        }
        centre.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: main
        ) { [weak self] _ in
            self?.isAppActive = true
            self?.updateDisplayLinkState()
        }
        for name in [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            NSNotification.Name("NSApplicationDidHideNotification"),
            NSNotification.Name("NSWindowDidMiniaturizeNotification")
        ] {
            centre.addObserver(forName: name, object: nil, queue: main) { [weak self] _ in
                self?.isAppActive = false
                self?.updateDisplayLinkState()
            }
        }
        updateDisplayLinkState()

        centre.addObserver(forName: NSNotification.Name(rawValue: "NSWindowDidBecomeKeyNotification"), object: nil,
            queue: main) { _ in
            if mode.cursorHidden() {
                AKInterface.shared!.warpCursor()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5, qos: .utility) {
            if mode.cursorHidden() || !ActionDispatcher.cursorHideNecessary {
                return
            }
            Toast.initialize()
        }
        mode.initialize()
    }

    private func updateDisplayLinkState() {
        let hasController = !GCController.controllers().isEmpty
        if !hasController {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        if isAppActive {
            if displayLink == nil {
                // Drain the main dispatch queue per frame while a GCController is active.
                let link = CADisplayLink(target: self, selector: #selector(drainMainDispatchQueue))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = false
        } else {
            displayLink?.isPaused = true
        }
    }

    private func simulateGCMouseDisconnect() {
        NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { nofitication in
            guard let mouse = nofitication.object as? GCMouse else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                NotificationCenter.default.post(name: .GCMouseDidDisconnect, object: mouse)
                mouse.mouseInput?.leftButton.pressedChangedHandler = nil
                mouse.mouseInput?.leftButton.valueChangedHandler = nil
                mouse.mouseInput?.rightButton?.pressedChangedHandler = nil
                mouse.mouseInput?.rightButton?.valueChangedHandler = nil
                mouse.mouseInput?.middleButton?.pressedChangedHandler = nil
                mouse.mouseInput?.middleButton?.valueChangedHandler = nil
                mouse.mouseInput?.auxiliaryButtons?.forEach { button in
                    button.pressedChangedHandler = nil
                    button.valueChangedHandler = nil
                }
                mouse.mouseInput?.scroll.valueChangedHandler = nil
                mouse.mouseInput?.mouseMovedHandler = nil
            }
        }
    }
}
