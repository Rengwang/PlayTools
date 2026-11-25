#!/usr/bin/env python3
"""Contract and math unit test for iPhone Duo Vertical Bar emulation in PlayTools."""

import re
import subprocess
import sys
import tempfile
from pathlib import Path


def read_text(path: Path) -> str:
    if not path.is_file():
        raise FileNotFoundError(f"Missing file: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


def check_source_contract(pt_root: Path) -> list[str]:
    pt_dir = pt_root / "PlayTools"
    settings = read_text(pt_dir / "PlaySettings.swift")
    loader_h = read_text(pt_dir / "PlayLoader.h")
    loader_m = read_text(pt_dir / "PlayLoader.m")
    duo = read_text(pt_dir / "DuoVerticalBarCompatibility.m")
    pbxproj = read_text(pt_root / "PlayTools.xcodeproj" / "project.pbxproj")

    failures: list[str] = []

    required = [
        ("PlaySettings:duoVerticalBarDefault", settings, "var duoVerticalBar = false"),
        ("PlaySettings:duoVerticalBarDecode", settings, "forKey: .duoVerticalBar) ?? false"),
        ("PlaySettings:duoVerticalBarProperty", settings, "lazy var duoVerticalBar = settingsData.duoVerticalBar"),
        ("PlaySettings:shouldEnableDuoVerticalBar", settings, "effectiveLayoutIdiom == 3 && settingsData.duoVerticalBar"),
        ("PlaySettings:duoDeviceModel", settings, 'return "iPhone19,4"'),
        ("PlayLoaderH:enableDecl", loader_h, "BOOL PTShouldEnableDuoVerticalBar(void);"),
        ("PlayLoaderM:installCall", loader_m, "pt_installDuoVerticalBarCompatibility();"),
        ("PlayLoaderM:duoModelDefault", loader_m, 'pt_cached_device_model_buf[128] = "iPhone19,4"'),
        ("Duo:enableImpl", duo, "return PlaySettings.shared.layoutIdiom == 3 && PlaySettings.shared.duoVerticalBar;"),
        ("Duo:optInEarlyReturn", duo, "if (!PTShouldEnableDuoVerticalBar())"),
        ("Duo:traitSystemAllowed", duo, '"_UITraitSystemVerticalBarAllowed"'),
        ("Duo:traitSystemEdge", duo, '"_UITraitSystemVerticalBarHorizontalEdge"'),
        ("Duo:traitAllowed", duo, '"_UITraitVerticalBarAllowed"'),
        ("Duo:traitSetInt", duo, "setNSIntegerValue:forTrait:"),
        ("Duo:traitRemove", duo, "removeTrait:"),
        ("Duo:preferredBehavior", duo, '"preferredVerticalBarBehavior"'),
        ("Duo:childPreferredBehavior", duo, '"childViewControllerForPreferredVerticalBarBehavior"'),
        ("Duo:needsUpdateConfig", duo, '"setNeedsUpdateOfVerticalBarConfiguration"'),
        ("Duo:sceneSafeAreaHook", duo, '"_sceneSafeAreaInsetsIncludingStatusBar:"'),
        ("Duo:sceneSafeAreaDidChange", duo, '"_sceneSettingsSafeAreaInsetsDidChange"'),
        ("Duo:regionEdgeExtent", duo, '"layoutRegionForBarOnEdge:extent:"'),
        ("Duo:regionDirEdgeExtent", duo, '"layoutRegionForBarOnDirectionalEdge:extent:"'),
        ("Duo:viewLayoutGuide", duo, '"layoutGuideForLayoutRegion:"'),
        ("Duo:viewEdgeInsets", duo, '"edgeInsetsForLayoutRegion:"'),
        ("Duo:viewDirEdgeInsets", duo, '"directionalEdgeInsetsForLayoutRegion:"'),
        ("Duo:autoYieldCheck", duo, "pt_windowHasAppRenderedRightSidebar"),
        ("Duo:hostViewClass", duo, "@implementation PTDuoVerticalBarHostView"),
        ("Duo:backButtonSymbol", duo, '"chevron.backward"'),
        ("Duo:axisBehaviorCheck", duo, '"axisBehavior"'),
        ("Duo:tabDelegateShouldSelect", duo, "tabBarController:shouldSelectViewController:"),
        ("Duo:tabBarRelocate", duo, "pt_setTabBarRelocatedHidden"),
        ("Duo:customTabBarGuard", duo, "pt_duoTabBarIsCustomReplacement"),
        ("Duo:navBarClassify", duo, "PTDuoClassifyNavBarSuppression"),
        ("Duo:navBarTopInsetAdjust", duo, "PTDuoAdjustedSuppressedNavBarTopInset"),
        ("Duo:navBarVisualSuppress", duo, "pt_setNavBarVisualSuppressed"),
        ("Duo:toolbarVisualSuppress", duo, "pt_setToolbarVisualSuppressed"),
        ("Duo:barItemHorizontalSuppress", duo, "pt_setBarItemHorizontalSuppressed"),
        ("Duo:navItemBackSuppress", duo, "pt_setNavItemBackButtonSuppressed"),
        ("Duo:navShouldInsetHook", duo, '"_shouldNavigationBarInsetViewController:"'),
        ("Duo:navEdgeInsetsHook", duo, '"_edgeInsetsForChildViewController:insetsAreAbsolute:"'),
        ("Duo:toolbarShouldInsetHook", duo, '"_shouldToolBar:insetViewController:"'),
        ("Duo:horizontalOnlyCheck", duo, "pt_barItemIsHorizontalOnly"),
        ("Duo:hitTestPassthrough", duo, "- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event"),
        ("pbxproj:DuoVerticalBarCompatibility", pbxproj, "DuoVerticalBarCompatibility.m"),
    ]
    for label, text, needle in required:
        if needle not in text:
            failures.append(f"MISSING {label}: '{needle}'")

    # Forbidden patterns: zero bundleIdentifier hardcodes, no AJX guard hack, no fake status bar chrome
    forbidden = [
        ("Duo:noBundleIdentifier", duo, "bundleIdentifier"),
        ("Duo:noAmapBundleId", duo, "com.autonavi.amap"),
        ("Duo:noBiliBundleId", duo, "tv.danmaku.bilianime"),
        ("Duo:noXhsBundleId", duo, "com.xingin.discover"),
        ("Duo:noWeWorkBundleId", duo, "com.tencent.ww"),
        ("Duo:noReservedRegionsHook", duo, "reservedRegionsOfKind:"),
        ("Duo:noFakeBatteryIcon", duo, "battery.100"),
        ("Duo:noFakeWifiIcon", duo, "wifi"),
        ("Duo:noFakeSignalIcon", duo, "cellularbars"),
        ("PlayLoaderM:noAJXSidebarDuoGuard", loader_m, "pt_installAJXSidebarDuoGuard"),
    ]
    for label, text, needle in forbidden:
        if needle in text:
            failures.append(f"FORBIDDEN {label}: found '{needle}'")

    # Ensure no hardcoded bundle IDs matching common reverse-DNS app prefixes in DuoVerticalBarCompatibility.m
    if re.search(r'"(com|cn|tv|org|net|io)\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_.-]+"', duo):
        failures.append("FORBIDDEN Duo:reverseDnsStringLiteral detected in DuoVerticalBarCompatibility.m")

    return failures


def run_math_unit_tests(pt_root: Path) -> list[str]:
    duo_path = pt_root / "PlayTools" / "DuoVerticalBarCompatibility.m"
    src = read_text(duo_path)
    start_marker = "// MARK: - PTDuoVerticalBarMath"
    end_marker = "// MARK: - Associated Object Keys & State Types"
    if start_marker not in src or end_marker not in src:
        return ["Math markers not found in DuoVerticalBarCompatibility.m"]

    math_block = src[src.index(start_marker):src.index(end_marker)]

    harness = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <assert.h>
#import <math.h>
#import <stdio.h>

typedef NS_OPTIONS(NSUInteger, UIRectEdge) {
    UIRectEdgeNone   = 0,
    UIRectEdgeTop    = 1 << 0,
    UIRectEdgeLeft   = 1 << 1,
    UIRectEdgeBottom = 1 << 2,
    UIRectEdgeRight  = 1 << 3,
    UIRectEdgeAll    = UIRectEdgeTop | UIRectEdgeLeft | UIRectEdgeBottom | UIRectEdgeRight
};

typedef NS_OPTIONS(NSUInteger, NSDirectionalRectEdge) {
    NSDirectionalRectEdgeNone     = 0,
    NSDirectionalRectEdgeTop      = 1 << 0,
    NSDirectionalRectEdgeLeading  = 1 << 1,
    NSDirectionalRectEdgeBottom   = 1 << 2,
    NSDirectionalRectEdgeTrailing = 1 << 3,
    NSDirectionalRectEdgeAll      = NSDirectionalRectEdgeTop | NSDirectionalRectEdgeLeading | NSDirectionalRectEdgeBottom | NSDirectionalRectEdgeTrailing
};

typedef NS_ENUM(NSInteger, UIUserInterfaceLayoutDirection) {
    UIUserInterfaceLayoutDirectionLeftToRight,
    UIUserInterfaceLayoutDirectionRightToLeft,
};

static const CGFloat kPTDuoVerticalBarWidth = 60.0;
static const CGFloat kPTDuoVerticalBarMinWindowWidth = 600.0;
static const CGFloat kPTDuoVerticalBarMinWindowHeight = 320.0;

''' + math_block + r'''

int main(void) {
    // 1. Activation gate & preferredVerticalBarBehavior opt-out
    assert(PTDuoShouldActivateForGeometry(YES, 900.0, 700.0, 0) == YES);
    assert(PTDuoShouldActivateForGeometry(YES, 600.0, 320.0, 0) == YES);
    assert(PTDuoShouldActivateForGeometry(NO, 900.0, 700.0, 0) == NO);
    assert(PTDuoShouldActivateForGeometry(YES, 599.0, 700.0, 0) == NO);
    assert(PTDuoShouldActivateForGeometry(YES, 900.0, 319.0, 0) == NO);
    assert(PTDuoShouldActivateForGeometry(YES, 900.0, 700.0, 1) == NO); // UIVerticalBarBehaviorDisabled
    assert(PTDuoShouldActivateForGeometry(YES, NAN, 700.0, 0) == NO);

    // 2. Physical & directional edge resolution
    assert(PTDuoResolvePhysicalBarEdge(NO, UIRectEdgeRight, NSDirectionalRectEdgeNone, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeRight);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeTrailing, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeRight);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeTrailing, UIUserInterfaceLayoutDirectionRightToLeft) == UIRectEdgeLeft);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeLeading, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeLeft);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeLeading, UIUserInterfaceLayoutDirectionRightToLeft) == UIRectEdgeRight);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeTop, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeTop);
    assert(PTDuoResolvePhysicalBarEdge(YES, UIRectEdgeNone, NSDirectionalRectEdgeBottom, UIUserInterfaceLayoutDirectionLeftToRight) == UIRectEdgeBottom);

    // 3. Extent resolution & clamping
    assert(fabs(PTDuoResolveBarExtent(YES, 48.0, 900.0) - 48.0) < 0.001);
    assert(fabs(PTDuoResolveBarExtent(NO, 0.0, 900.0) - 60.0) < 0.001);
    assert(fabs(PTDuoResolveBarExtent(YES, -5.0, 900.0) - 60.0) < 0.001);
    assert(fabs(PTDuoResolveBarExtent(YES, NAN, 900.0) - 60.0) < 0.001);
    assert(fabs(PTDuoResolveBarExtent(YES, 60.0, 40.0) - 40.0) < 0.001);

    // 4. App-rendered custom sidebar auto-yield geometry candidate checks
    CGRect win = CGRectMake(0, 0, 900, 700);
    // Custom 48pt sidebar (e.g. AJXSidebarView) pinned inside right 60pt strip -> candidate YES
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(846, 20, 48, 660), win) == YES);
    // Compact right-edge floating action column (36x120) -> candidate YES
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(852, 80, 36, 120), win) == YES);
    // Full-window map/content container -> NOT a sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(0, 0, 900, 700), win) == NO);
    // Wide panel (200pt) -> NOT a sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(700, 0, 200, 700), win) == NO);
    // Left-edge sidebar -> NOT a right-strip sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(6, 20, 48, 660), win) == NO);
    // Scrollbar indicator (6pt wide) -> too narrow, NOT a sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(892, 40, 6, 180), win) == NO);
    // Tiny badge (30x24) -> too short, NOT a sidebar candidate
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(860, 40, 30, 24), win) == NO);
    // Narrow window (<600pt) -> NO
    assert(PTDuoRectIsAppSidebarCandidate(CGRectMake(446, 20, 48, 660), CGRectMake(0, 0, 500, 700)) == NO);

    // 5. Horizontal UINavigationBar / UIToolbar deduplication classification & top-inset collapse
    // Case 1: bar visible, items relocated, no title/titleView/search/leading/HorizontalOnly -> Full suppression
    assert(PTDuoClassifyNavBarSuppression(YES, YES, NO) == PTDuoNavBarSuppressionFull);
    // Case 2: bar visible, items relocated, has title/search/HorizontalOnly content -> ItemsOnly suppression
    assert(PTDuoClassifyNavBarSuppression(YES, YES, YES) == PTDuoNavBarSuppressionItemsOnly);
    // App already hid bar OR nothing relocated -> None
    assert(PTDuoClassifyNavBarSuppression(NO, YES, NO) == PTDuoNavBarSuppressionNone);
    assert(PTDuoClassifyNavBarSuppression(YES, NO, NO) == PTDuoNavBarSuppressionNone);
    assert(PTDuoClassifyNavBarSuppression(YES, NO, YES) == PTDuoNavBarSuppressionNone);

    // Top-inset collapse preserves window safe area (e.g. 32pt traffic lights) while removing 54pt navBar push
    assert(fabs(PTDuoAdjustedSuppressedNavBarTopInset(86.0, YES, 32.0) - 32.0) < 0.001);
    assert(fabs(PTDuoAdjustedSuppressedNavBarTopInset(28.0, YES, 32.0) - 28.0) < 0.001);
    assert(fabs(PTDuoAdjustedSuppressedNavBarTopInset(54.0, NO, 32.0) - 0.0) < 0.001);
    assert(fabs(PTDuoAdjustedSuppressedNavBarTopInset(NAN, YES, 32.0) - 0.0) < 0.001);

    printf("ALL_MATH_CHECKS_PASSED\n");
    return 0;
}
'''

    with tempfile.TemporaryDirectory() as tmp:
        src_file = Path(tmp) / "test_duo_math.m"
        bin_file = Path(tmp) / "test_duo_math"
        src_file.write_text(harness, encoding="utf-8")
        cc = subprocess.run(
            [
                "xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra",
                "-framework", "Foundation", "-framework", "CoreGraphics",
                str(src_file), "-o", str(bin_file),
            ],
            capture_output=True, text=True, check=False,
        )
        if cc.returncode != 0:
            return [f"Math harness compile failed:\n{cc.stderr}"]
        run = subprocess.run([str(bin_file)], capture_output=True, text=True, check=False)
        if run.returncode != 0 or "ALL_MATH_CHECKS_PASSED" not in run.stdout:
            return [f"Math harness failed (rc={run.returncode}): {run.stdout} {run.stderr}"]
    return []


def main() -> int:
    pt_root = Path(__file__).resolve().parents[1]
    failures = check_source_contract(pt_root) + run_math_unit_tests(pt_root)
    if failures:
        print(f"Duo Vertical Bar contract test FAILED ({len(failures)} issues):")
        for f in failures:
            print(f"  FAIL: {f}")
        return 1
    print("PASS: Duo Vertical Bar contract and geometry tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
