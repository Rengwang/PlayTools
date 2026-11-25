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
    swizzle = read_text(pt_dir / "Controls" / "PTFakeTouch" / "NSObject+Swizzle.m")
    camera = read_text(pt_dir / "CameraCompatibility.m")
    screen = read_text(pt_dir / "PlayScreen.swift")
    pbxproj = read_text(root / "PlayTools" / "PlayTools.xcodeproj" / "project.pbxproj")

    required_tokens = [
        ("PlayLoader:proxySettings", loader, "pt_CFNetworkCopySystemProxySettings"),
        ("PlayLoader:proxiesForURL", loader, "pt_CFNetworkCopyProxiesForURL"),
        ("PlayLoader:startupPresentation", loader, "pt_presentViewControllerAtStartup"),
        ("PlayLoader:orphanSceneGuard", loader, "pt_installOrphanWindowSceneGuard"),
        ("PlayLoader:spaceFreeAppGroup", loader, "PlayCoverGroupContainers"),
        ("PlayLoader:MarketplaceKitWeak", loader, "MarketplaceKit"),
        ("PlayLoader:WirelessInsightsWeak", loader, "WirelessInsights"),
        ("PlayLoader:WirelessInsightsVersion", loader, "0x001a0000"),
        ("PlayLoader:MarketplaceKitVersion", loader, "0x00110400"),
        ("PlayLoader:mscWebViewMouseTouchBridge", loader, "pt_installMSCMouseTouchCompatibility"),
        ("Camera:previewOnlyMirroring", camera, "if (!connection.videoPreviewLayer)"),
        ("Swizzle:FacebookBundleInfo", swizzle, "pt_installNSBundleInfoSwizzlesOnce"),
        ("pbxproj:OneNoteSceneCompatibility", pbxproj, "OneNoteSceneCompatibility.m"),
        ("Camera:alignedHorizonAngle", camera, "pt_alignedHorizonAngle"),
        ("Camera:useNativePlatformFlag", camera, "!PlaySettings.shared.useNativePlatform"),
        ("Camera:perRoleMirroring", camera, "pt_applyCameraMirroring"),
        ("Camera:perInputRoleTracking", camera, "pt_requestedCameraRoleForConnection"),
        ("PlayScreen:exceedsFullCanvasGuard", screen, "exceedsFullCanvas"),
        ("PlayScreen:scaledZeroHeightSelfTest", screen, "geometry.scaled.zeroHeightStatusBarNonBlocking"),
        ("PlayScreen:scaledOversizedSelfTest", screen, "geometry.scaled.oversizedFullscreenClamped"),
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

    # Ensure App Group path resolves under Library/PlayCoverGroupContainers (space-free), not Library/Application Support
    if 'URLByAppendingPathComponent:@"PlayCoverGroupContainers"' in loader and "NSLibraryDirectory" in loader:
        passed.append("PlayLoader:libraryGroupContainersRoot")
    else:
        failures.append("PlayLoader: missing NSLibraryDirectory + PlayCoverGroupContainers root")

    # Forbidden tokens: temp traces and bundle-ID camera hardcodes
    forbidden = [
        ("PlayLoader:noTempUmetripTrace", loader, "TEMP_UMETRIP_TRACE"),
        ("Camera:noTempCamTrace", camera, "PC_CAMTRACE"),
        ("Camera:noBundleIdHardcode", camera, "bundleIdentifier"),
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


def check_tests(root: Path, failures: list[str], passed: list[str]) -> None:
    """Run lightweight regression unit and lifecycle scripts."""
    lifecycle = root / "PlayTools" / "Tests" / "check-input-lifecycle.py"
    if lifecycle.is_file():
        res = subprocess.run([sys.executable, str(lifecycle)], capture_output=True, text=True, check=False)
        if res.returncode == 0:
            passed.append("Test:check-input-lifecycle")
        else:
            failures.append(f"Test:check-input-lifecycle failed: {res.stdout} {res.stderr}")

    msc_bridge = root / "PlayTools" / "Tests" / "check-msc-mouse-bridge.py"
    if msc_bridge.is_file():
        res = subprocess.run([sys.executable, str(msc_bridge)], capture_output=True, text=True, check=False)
        if res.returncode == 0:
            passed.append("Test:check-msc-mouse-bridge")
        else:
            failures.append(f"Test:check-msc-mouse-bridge failed: {res.stdout} {res.stderr}")

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
