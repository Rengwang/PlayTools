#!/usr/bin/env python3
"""Automated compatibility invariant checker for PlayCover + PlayTools.

Guards against regressions across merges/rebases by verifying critical source hooks,
Xcode project membership, Absence of temporary diagnostic traces, Mach-O symbols,
codesigning, matching framework UUIDs, and unit/contract scripts.
"""

import os
import re
import subprocess
import sys
from pathlib import Path


def resolve_workspace_root() -> Path:
    """Resolve the dual-repository workspace root containing PlayTools and PlayCover."""
    here = Path(__file__).resolve()
    # PlayTools/Tests/check-compat-invariants.py -> workspace root
    root = here.parent.parent.parent
    if (root / "PlayTools" / "PlayTools").is_dir():
        return root
    return Path.cwd()


def read_text(path: Path) -> str:
    """Read a UTF-8 file, failing loudly if it does not exist."""
    if not path.is_file():
        raise FileNotFoundError(f"Missing required file: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def check_source_invariants(root: Path, failures: list[str], passed: list[str]) -> None:
    """Check critical source files, Xcode target membership, and absence of temp traces."""
    pt_dir = root / "PlayTools" / "PlayTools"
    loader = read_text(pt_dir / "PlayLoader.m")
    settings = read_text(pt_dir / "PlaySettings.swift")
    swizzle = read_text(pt_dir / "Controls" / "PTFakeTouch" / "NSObject+Swizzle.m")
    camera = read_text(pt_dir / "CameraCompatibility.m")
    screen = read_text(pt_dir / "PlayScreen.swift")
    ak_plugin = read_text(root / "PlayTools" / "AKPlugin.swift")
    plugin_proto = read_text(root / "PlayTools" / "Plugin.swift")
    option_zoom = read_text(pt_dir / "Controls" / "OptionScrollZoomController.swift")
    ak_loader = read_text(pt_dir / "Utils" / "AKPluginLoader.swift")
    location = read_text(pt_dir / "LocationCompatibility.m")
    duo_vbar = read_text(pt_dir / "DuoVerticalBarCompatibility.m")
    eff_hooks = read_text(pt_dir / "PlayEfficiencyHooks.m")
    pbxproj = read_text(root / "PlayTools" / "PlayTools.xcodeproj" / "project.pbxproj")

    required_tokens = [
        ("PlayLoader:proxySettings", loader, "pt_CFNetworkCopySystemProxySettings"),
        ("PlayLoader:proxiesForURL", loader, "pt_CFNetworkCopyProxiesForURL"),
        ("PlayLoader:startupPresentation", loader, "pt_presentViewControllerAtStartup"),
        ("PlayLoader:orphanSceneGuard", loader, "pt_installOrphanWindowSceneGuard"),
        ("PlayLoader:spaceFreeAppGroup", loader, "PlayCoverGroupContainers"),
        ("PlayLoader:MarketplaceKitWeak", loader, "MarketplaceKit"),
        ("PlayLoader:WirelessInsightsWeak", loader, "WirelessInsights"),
        ("PlayLoader:WirelessInsightsCompatSubpath", loader, "WirelessInsightsCompatibility/WirelessInsights.framework/WirelessInsights"),
        ("PlayLoader:WirelessInsightsRebind", loader, "pt_rebind_weak_chained_fixups_in_image"),
        ("PlayLoader:WirelessInsightsVersion", loader, "0x001a0000"),
        ("PlayLoader:MarketplaceKitVersion", loader, "0x00110400"),
        ("pbxproj:WirelessInsightsCompatibility", pbxproj, "Build WirelessInsights compatibility"),
        ("PlayLoader:mscWebViewMouseTouchBridge", loader, "pt_installMSCMouseTouchCompatibility"),
        ("PlayLoader:locationCompatibility", loader, "pt_installLocationCompatibility"),
        ("PlayLoader:appearanceReentrancyGuard", loader, "pt_installWindowAppearanceReentrancyGuard"),
        ("Location:weakDelegateBox", location, "PTWeakDelegateBox"),
        ("Location:threadSafeTimerBox", location, "@synchronized(self)"),
        ("PlayLoader:dcUniSplash", loader, "DCUniSplashAd"),
        ("PlayLoader:gdtTangramSplash", loader, "showSplashWithOrder:withCustomUI:inContainerView:"),
        ("PlayLoader:miguSplash", loader, "MGPolymerAdSDKLaunchAdRequestSerialization"),
        ("PlayLoader:qlSplashGate", loader, "QLAppLaunchMananger"),
        ("PlayLoader:gmSplash", loader, "GMSplashAd"),
        ("PlayLoader:windMillSwiftSplash", loader, "_TtC11WindMillSDK16WindMillSplashAd"),
        ("PlayLoader:atShowSplash", loader, "showSplashWithPlacementID:config:window:inViewController:extra:delegate:nativeMixViewBlock:"),
        ("PlayLoader:asnpSplash", loader, "ASNPSplashAd"),
        ("PlayLoader:adScopeSplash", loader, "AdScopeADNSplashAd"),
        ("PlayLoader:maAppOpenAd", loader, "MAAppOpenAd"),
        ("PlayLoader:ujuSplash", loader, "UjuMagicSplashAd"),
        ("PlayLoader:natanxSplash", loader, "TXAdSplashManager"),
        ("PlayLoader:miguBootSplash", loader, "MIGUBootScreenAd"),
        ("PlayLoader:dcBasicSplash", loader, "DCBasicSplashAdViewController"),
        ("PlayLoader:kwSplash", loader, "KWSplashManager"),
        ("PlayLoader:mppSplash", loader, "MPPSplashAd"),
        ("PlayLoader:bfcSplash", loader, "BFCSplashManager"),
        ("PlayLoader:xySplashFreq", loader, "_TtC11XYAdsSplash30SplashAdsMultiFrequencyControl"),
        ("PlayLoader:nmLaunchAd", loader, "NMLaunchAdViewManager"),
        ("PlayLoader:wbAdLauncher", loader, "WBAdSdkLauncher"),
        ("PlayLoader:qyStartAd", loader, "QYPhoneStartADManager"),
        ("PlayLoader:pddSplash", loader, "PDDSplashManager"),
        ("PlayLoader:winSplash", loader, "WINSplashScreenVAppService"),
        ("PlayLoader:winSplashError", loader, "WINSplashScreenError"),
        ("PlayLoader:youkuSplash", loader, "canShowColdSplash"),
        ("PlayLoader:zhihuSplash", loader, "ZHZADLaunchDisable"),
        ("PlayLoader:tmeSplash", loader, "TMEAdOperateIntervalManager"),
        ("PlayLoader:qqGdtSplash", loader, "GdtSplashAdManager"),
        ("PlayLoader:taobaoSplash", loader, "TBBootImageManager"),
        ("PlayLoader:fishSplash", loader, "_TtC6FishAd18FishSplashAdLoader"),
        ("PlayLoader:customTabBarPlatterGuard", loader, "pt_updateCustomTabBarPlatterVisibility"),
        ("PlayLoader:customTabBarPlatterClass", loader, "_UITabBarItemPlatterView"),
        ("PlayLoader:customTabBarMultiSubview", loader, "pt_tabBarHasCustomReplacementSubviews"),
        ("PlayLoader:customTabBarSetSelectedItem", loader, "pt_tabBarSetSelectedItem"),
        ("PlayLoader:duoDefaultModel", loader, 'pt_cached_device_model_buf[128] = "iPhone19,4"'),
        ("PlaySettings:duoEffectiveModel", settings, 'return "iPhone19,4"'),
        ("PlaySettings:duoVerticalBarDefault", settings, "var duoVerticalBar = false"),
        ("PlaySettings:duoVerticalBarDecodeDefault", settings, "forKey: .duoVerticalBar) ?? false"),
        ("PlayLoader:duoVerticalBarCompatibility", loader, "pt_installDuoVerticalBarCompatibility"),
        ("DuoVerticalBar:enableGate", duo_vbar, "PTShouldEnableDuoVerticalBar"),
        ("DuoVerticalBar:hostView", duo_vbar, "PTDuoVerticalBarHostView"),
        ("DuoVerticalBar:layoutRegionGuide", duo_vbar, "layoutGuideForLayoutRegion:"),
        ("DuoVerticalBar:preferredBehavior", duo_vbar, "preferredVerticalBarBehavior"),
        ("DuoVerticalBar:navBarDedup", duo_vbar, "PTDuoClassifyNavBarSuppression"),
        ("DuoVerticalBar:navInsetCollapse", duo_vbar, "_edgeInsetsForChildViewController:insetsAreAbsolute:"),
        ("DuoVerticalBar:recursiveChildDescent", duo_vbar, "pt_largestVisibleChildViewController"),
        ("DuoVerticalBar:modernTabsProminent", duo_vbar, "prominentTabIdentifier"),
        ("DuoVerticalBar:navBarHiddenBackGuard", duo_vbar, "PTDuoShouldShowSyntheticBackButton"),
        ("DuoVerticalBar:emptyRightInsetCollapse", duo_vbar, "PTDuoShouldCollapseEmptyRightInset"),
        ("DuoVerticalBar:barRegionStripMath", duo_vbar, "PTDuoBarRegionEdgeInsets"),
        ("DuoVerticalBar:occupiedRightBarWidth", duo_vbar, "PTDuoResolveOccupiedRightBarWidth"),
        ("DuoVerticalBar:swiftLayoutRegionInterpose", duo_vbar, "_$sSo6UIViewC5UIKitE10edgeInsets3forSo06UIEdgeD0VAbCE12LayoutRegionV_tF"),
        ("DuoVerticalBar:swiftDirLayoutRegionInterpose", duo_vbar, "_$sSo6UIViewC5UIKitE21directionalEdgeInsets3forSo013NSDirectionaldE0VAbCE12LayoutRegionV_tF"),
        ("DuoVerticalBar:swiftGuideLayoutRegionInterpose", duo_vbar, "_$sSo6UIViewC5UIKitE11layoutGuide3forSo08UILayoutD0CAbCE12LayoutRegionV_tF"),
        ("DuoVerticalBar:adjustRightBarMath", duo_vbar, "PTDuoAdjustRightBarEdgeInsets"),
        ("pbxproj:DuoVerticalBarCompatibility", pbxproj, "DuoVerticalBarCompatibility.m"),
        ("PlaySettings:hideTitleBarDefault", settings, "var hideTitleBar = true"),
        ("PlaySettings:hideTitleBarDecodeDefault", settings, "forKey: .hideTitleBar) ?? true"),
        ("AKPlugin:hideTitleBarDefault", ak_plugin, "hideTitleBar ?? true"),
        ("Camera:previewOnlyMirroring", camera, "if (!connection.videoPreviewLayer)"),
        ("Swizzle:FacebookBundleInfo", swizzle, "pt_installNSBundleInfoSwizzlesOnce"),
        ("pbxproj:OneNoteSceneCompatibility", pbxproj, "OneNoteSceneCompatibility.m"),
        ("pbxproj:LocationCompatibility", pbxproj, "LocationCompatibility.m"),
        ("Camera:alignedHorizonAngle", camera, "pt_alignedHorizonAngle"),
        ("Camera:useNativePlatformFlag", camera, "!PlaySettings.shared.useNativePlatform"),
        ("Camera:perRoleMirroring", camera, "pt_applyCameraMirroring"),
        ("Camera:perInputRoleTracking", camera, "pt_requestedCameraRoleForConnection"),
        ("PlayScreen:exceedsFullCanvasGuard", screen, "exceedsFullCanvas"),
        ("PlayScreen:iPadNoRuntimeFallback", screen, "!appCapabilities.supportsIPad"),
        ("PlayScreen:scaledZeroHeightSelfTest", screen, "geometry.scaled.zeroHeightStatusBarNonBlocking"),
        ("PlayScreen:scaledOversizedSelfTest", screen, "geometry.scaled.oversizedFullscreenClamped"),
        ("AKPlugin:savedWindowFrame", ak_plugin, "PlayCover.SavedWindowFrame.v1"),
        ("AKPluginLoader:preferFrameworkPlugin", ak_loader, "Bundle(for: AKInterface.self)"),
        ("PlaySettings:optionScrollZoomDefault", settings, "var optionScrollZoom = true"),
        ("PlaySettings:optionScrollZoomDecodeDefault", settings, "forKey: .optionScrollZoom) ?? true"),
        ("PlaySettings:optionScrollZoomDict", settings, '"optionScrollZoom": settingsData.optionScrollZoom'),
        ("Plugin:setupOptionScrollZoom", plugin_proto, "setupOptionScrollZoom"),
        ("AKPlugin:optionScrollZoomSetting", ak_plugin, "optionScrollZoom ?? true"),
        ("AKPlugin:setupOptionScrollZoom", ak_plugin, "func setupOptionScrollZoom("),
        ("OptionScrollZoom:controller", option_zoom, "class OptionScrollZoomController"),
        ("pbxproj:OptionScrollZoomController", pbxproj, "OptionScrollZoomController.swift"),
        ("Swizzle:cmVirtualAlmondDeallocGuard", swizzle, "pt_CMMotionManager_dealloc"),
        ("PlayLoader:skylightPrewarm", loader, "pt_ensure_skylight_prewarmed"),
        ("PlayLoader:notificationRecursionGuard", loader, "pt_installNotificationRecursionGuard"),
        ("PlayEfficiency:liveResizeWake", eff_hooks, "pt_hostWindowLiveResizing"),
        ("DuoVerticalBar:liveResizeDefer", duo_vbar, "pt_duoHostLiveResizing"),
        ("PlayScreen:liveResizePacing", screen, "nextAdaptiveResizePacingInterval"),
        ("Swizzle:liveResizeBoundsCoalesce", swizzle, "pt_isPlayScreenAdaptiveLiveResizePacing"),
    ]
    for name, content, token in required_tokens:
        if token in content:
            passed.append(name)
        else:
            failures.append(f"{name}: missing required token '{token}'")

    if not (pt_dir / "OneNoteSceneCompatibility.m").is_file():
        failures.append("OneNote: OneNoteSceneCompatibility.m missing")
    else:
        passed.append("OneNote:sourceFileExists")

    if not (pt_dir / "LocationCompatibility.m").is_file():
        failures.append("Location: LocationCompatibility.m missing")
    else:
        passed.append("Location:sourceFileExists")

    if not (pt_dir / "DuoVerticalBarCompatibility.m").is_file():
        failures.append("DuoVerticalBar: DuoVerticalBarCompatibility.m missing")
    else:
        passed.append("DuoVerticalBar:sourceFileExists")

    # --- Risk-SDK neutralisation contract ---------------------------------
    # Guardrails so the diagnostic/anti-risk code cannot regress into global
    # overhead, unbounded scanning, or bundle-specific special cases.
    risk_contract = [
        ("RiskProbe:defaultSilent",
         "if (!pt_riskProbeVerbose()) {",
         loader),
        ("RiskProbe:optInLog",
         "if (!pt_riskProbeVerbose()) return;",
         loader),
        ("RiskNeutralize:importPrefilter",
         "pt_countSensitiveImports",
         loader),
        ("RiskNeutralize:familyGate",
         "pt_countInlineExitStubs",
         loader),
        ("RiskNeutralize:callgraphMatcher",
         "pt_findPredicateByCallgraph",
         loader),
        ("RiskNeutralize:prologueFallback",
         "pt_findPredicateByPrologue",
         loader),
        ("RiskNeutralize:skipSelfImage",
         "/PlayTools.framework/",
         loader),
        ("RiskNeutralize:boundedTextEnd",
         "seg->filesize < seg->vmsize ? seg->filesize : seg->vmsize",
         loader),
        ("RiskNeutralize:offSwitch",
         'environment][@"PT_RISK_NEUTRALIZE"]',
         loader),
        ("RiskBanner:offSwitch",
         'environment][@"PT_RISK_BANNER"]',
         loader),
        ("RiskNeutralize:slotContentMatch",
         "pt_collectSensitiveGotSlots",
         loader),
        ("RiskNeutralize:dlsymNameNormalised",
         "if (symbol[0] == '_') symbol++;",
         loader),
    ]
    for name, token, content in risk_contract:
        if token in content:
            passed.append(name)
        else:
            failures.append(f"{name}: missing token '{token}'")

    # The old fixed 64-slot window silently dropped later __got entries; slot
    # identity must come from content matching instead.
    if "slot >= 64" not in loader and "pt_gotSlotIndex" not in loader:
        passed.append("RiskNeutralize:noSlotWindowCap")
    else:
        failures.append("RiskNeutralize:noSlotWindowCap: fixed 64-slot window came back")

    # Ensure App Group path resolves under Library/PlayCoverGroupContainers (space-free), not Library/Application Support
    if 'URLByAppendingPathComponent:@"PlayCoverGroupContainers"' in loader and "NSLibraryDirectory" in loader:
        passed.append("PlayLoader:libraryGroupContainersRoot")
    else:
        failures.append("PlayLoader: missing NSLibraryDirectory + PlayCoverGroupContainers root")

    # Forbidden tokens: temp traces and bundle-ID hardcodes
    forbidden = [
        ("PlayLoader:noTempUmetripTrace", loader, "TEMP_UMETRIP_TRACE"),
        ("Camera:noTempCamTrace", camera, "PC_CAMTRACE"),
        ("Camera:noBundleIdHardcode", camera, "bundleIdentifier"),
        ("Location:noBundleIdHardcode", location, "bundleIdentifier"),
        ("DuoVerticalBar:noBundleIdHardcode", duo_vbar, "bundleIdentifier"),
        ("OptionScrollZoom:noBundleIdHardcode", option_zoom, "bundleIdentifier"),
        ("PlayLoader:noAJXSidebarDuoGuard", loader, "pt_installAJXSidebarDuoGuard"),
        ("PlayLoader:noXhsBundleHardcode", loader, "com.xingin.discover"),
        ("PlayLoader:noAwemeBundleHardcode", loader, "com.ss.iphone.ugc.Aweme"),
        ("PlayLoader:noAmapBundleHardcode", loader, "com.autonavi.amap"),
        ("PlayLoader:noWinSplashPlainNSError", loader, "WINSplashForbidden"),
        ("PlaySettings:noAmapBundleHardcode", settings, "com.autonavi.amap"),
    ]
    for name, content, token in forbidden:
        if token not in content:
            passed.append(name)
        else:
            failures.append(f"{name}: forbidden token '{token}' found")


def check_installed_invariants(root: Path, failures: list[str], passed: list[str]) -> None:
    """Verify signed PlayCover.app, matching PlayTools UUIDs, and compiled Mach-O strings."""
    app_path = Path("/Applications/PlayCover.app")
    embedded_pt = app_path / "Contents" / "Frameworks" / "PlayTools.framework" / "PlayTools"
    shared_pt = Path.home() / "Library" / "Frameworks" / "PlayTools.framework" / "PlayTools"

    if not app_path.exists() or not embedded_pt.exists():
        failures.append("Install: /Applications/PlayCover.app or embedded PlayTools missing")
        return

    cs = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app_path)],
        capture_output=True, text=True, check=False,
    )
    if cs.returncode == 0:
        passed.append("Install:codesignStrict")
    else:
        failures.append(f"Install:codesignStrict failed: {cs.stderr.strip()}")

    if not shared_pt.exists():
        failures.append(f"Install: shared PlayTools missing at {shared_pt}")
    else:
        du = subprocess.run(
            ["xcrun", "dwarfdump", "--uuid", str(embedded_pt), str(shared_pt)],
            capture_output=True, text=True, check=False,
        )
        uuids = re.findall(r"UUID:\s*([0-9A-Fa-f-]+)", du.stdout)
        if len(uuids) >= 2 and len(set(uuids)) == 1:
            passed.append(f"Install:matchingUUID({uuids[0]})")
        else:
            failures.append(f"Install: PlayTools UUID mismatch: {du.stdout.strip()}")

    st = subprocess.run(["strings", str(embedded_pt)], capture_output=True, text=True, errors="ignore", check=False)
    macho_strings = st.stdout
    for s_name, needle in [
        ("MachO:OneNote", "ONISplashScreenViewController"),
        ("MachO:AppGroup", "PlayCoverGroupContainers"),
        ("MachO:MarketplaceKit", "$s14MarketplaceKit14AppDistributorOMn"),
        ("MachO:WirelessInsights", "$s16WirelessInsights25ServicePredictionProviderCMn"),
        ("MachO:HorizonPreview", "videoRotationAngleForHorizonLevelPreview"),
        ("MachO:VideoMirrored", "setVideoMirrored:"),
        ("MachO:MSCMouseTouchBridge", "__ptMscMouseTouchBridgeInstalled"),
        ("MachO:LocationCompat", "PTLocationTimerBox"),
        ("MachO:DuoVerticalBar", "PTDuoVerticalBarHostView"),
    ]:
        if needle in macho_strings:
            passed.append(s_name)
        else:
            failures.append(f"{s_name}: missing compiled string '{needle}'")

    ios_slice = (
        root / "PlayCover" / "Carthage" / "Build" / "PlayTools.xcframework"
        / "ios-arm64" / "PlayTools.framework" / "PlayTools"
    )
    if ios_slice.is_file():
        ios_st = subprocess.run(["strings", str(ios_slice)], capture_output=True, text=True, errors="ignore", check=False)
        if "__ptMscMouseTouchBridgeInstalled" in ios_st.stdout or "pt_installMSCMouseTouchCompatibility" in ios_st.stdout:
            failures.append("XCFramework:iosSliceExcludesMSCBridge: unexpected MSC mouse-touch bridge found in ios-arm64 slice")
        else:
            passed.append("XCFramework:iosSliceExcludesMSCBridge")
        if "PTLocationTimerBox" in ios_st.stdout or "pt_installLocationCompatibility" in ios_st.stdout:
            failures.append("XCFramework:iosSliceExcludesLocationCompat: unexpected LocationCompatibility found in ios-arm64 slice")
        else:
            passed.append("XCFramework:iosSliceExcludesLocationCompat")
        if "PTDuoVerticalBarHostView" in ios_st.stdout or "pt_installDuoVerticalBarCompatibility" in ios_st.stdout:
            failures.append("XCFramework:iosSliceExcludesDuoVerticalBar: unexpected DuoVerticalBarCompatibility found in ios-arm64 slice")
        else:
            passed.append("XCFramework:iosSliceExcludesDuoVerticalBar")


def check_tests(root: Path, failures: list[str], passed: list[str]) -> None:
    """Run lightweight regression unit and lifecycle scripts."""
    lifecycle = root / "PlayTools" / "Tests" / "check-input-lifecycle.py"
    if lifecycle.is_file():
        res = subprocess.run([sys.executable, str(lifecycle)], capture_output=True, text=True, check=False)
        if res.returncode == 0:
            passed.append("Test:check-input-lifecycle")
        else:
            failures.append(f"Test:check-input-lifecycle failed: {res.stdout} {res.stderr}")

    option_zoom_test = root / "PlayTools" / "Tests" / "check-option-scroll-zoom.py"
    if option_zoom_test.is_file():
        res = subprocess.run([sys.executable, str(option_zoom_test)], capture_output=True, text=True, check=False)
        if res.returncode == 0:
            passed.append("Test:check-option-scroll-zoom")
        else:
            failures.append(f"Test:check-option-scroll-zoom failed: {res.stdout} {res.stderr}")

    msc_bridge = root / "PlayTools" / "Tests" / "check-msc-mouse-bridge.py"
    if msc_bridge.is_file():
        res = subprocess.run([sys.executable, str(msc_bridge)], capture_output=True, text=True, check=False)
        if res.returncode == 0:
            passed.append("Test:check-msc-mouse-bridge")
        else:
            failures.append(f"Test:check-msc-mouse-bridge failed: {res.stdout} {res.stderr}")

    duo_vbar_test = root / "PlayTools" / "Tests" / "check-duo-vertical-bar.py"
    if duo_vbar_test.is_file():
        res = subprocess.run([sys.executable, str(duo_vbar_test)], capture_output=True, text=True, check=False)
        if res.returncode == 0:
            passed.append("Test:check-duo-vertical-bar")
        else:
            failures.append(f"Test:check-duo-vertical-bar failed: {res.stdout} {res.stderr}")

    global_back_test = root / "PlayTools" / "Tests" / "check-global-back.py"
    if global_back_test.is_file():
        res = subprocess.run([sys.executable, str(global_back_test)], capture_output=True, text=True, check=False)
        if res.returncode == 0:
            passed.append("Test:check-global-back")
        else:
            failures.append(f"Test:check-global-back failed: {res.stdout} {res.stderr}")

    routing = root / "build" / "diagnostics" / "installed-compat" / "camera" / "cross-app" / "test-routing"
    if routing.is_file() and os.access(routing, os.X_OK):
        res = subprocess.run([str(routing)], capture_output=True, text=True, check=False)
        if res.returncode == 0:
            passed.append("Test:camera-test-routing")
        else:
            failures.append(f"Test:camera-test-routing failed: {res.stdout} {res.stderr}")


def main() -> int:
    root = resolve_workspace_root()
    failures: list[str] = []
    passed: list[str] = []

    check_source_invariants(root, failures, passed)
    if "--source-only" not in sys.argv:
        check_installed_invariants(root, failures, passed)
        check_tests(root, failures, passed)

    print(f"PlayCover/PlayTools Compatibility Invariants: {len(passed)} passed, {len(failures)} failed")
    for p in passed:
        print(f"  PASS {p}")
    for f in failures:
        print(f"  FAIL {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
