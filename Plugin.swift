//
//  Plugin.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import Foundation

@objc(Plugin)
public protocol Plugin: NSObjectProtocol {
    init()

    var screenCount: Int { get }
    var mousePoint: CGPoint { get }
    var windowFrame: CGRect { get }
    var contentLayoutRect: CGRect { get }
    var mainScreenFrame: CGRect { get }
    var isMainScreenEqualToFirst: Bool { get }
    var isFullscreen: Bool { get }
    @objc optional var isApplicationActive: Bool { get }
    @objc optional var hasVisibleUnminiaturizedWindow: Bool { get }
    var cmdPressed: Bool { get }

    func hideCursor()
    func hideCursorMove()
    func warpCursor()
    func unhideCursor()
    func terminateApplication()
    func setupKeyboard(keyboard: @escaping (UInt16, Bool, Bool, Bool) -> Bool,
                       swapMode: @escaping () -> Bool)
    func setupMouseMoved(_ mouseMoved: @escaping (CGFloat, CGFloat) -> Bool)
    func setupMouseButton(left: Bool, right: Bool, _ consumed: @escaping (Int, Bool) -> Bool)
    func setupScrollWheel(_ onMoved: @escaping (CGFloat, CGFloat) -> Bool)
    @objc optional func setupOptionScrollZoom(
        _ onZoom: @escaping (CGFloat, CGFloat, CGFloat, Bool) -> Bool,
        onEnd: @escaping () -> Void
    )
    @objc optional func setupGlobalBackIntegration(
        queryState: @escaping (Bool) -> Int,
        performBack: @escaping (Bool) -> Bool
    )
    @objc optional func setupGlobalHomeIntegration(
        queryHome: @escaping () -> Bool,
        performHome: @escaping () -> Bool
    )
    @objc optional func refreshGlobalBackUI()
    func urlForApplicationWithBundleIdentifier(_ value: String) -> URL?
    func setMenuBarVisible(_ value: Bool)
    func applyWindowAspectLock(width: CGFloat, height: CGFloat, minWidth: CGFloat, minHeight: CGFloat)
    func clearWindowAspectLock(minWidth: CGFloat, minHeight: CGFloat)
    func placeWindowOnTargetScreenIfNeeded()
}
