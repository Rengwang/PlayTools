#!/usr/bin/env python3
"""Contract and runtime verification for WirelessInsights Catalyst compatibility.

Verifies:
1. Built PlayTools.framework bundles WirelessInsightsCompatibility/WirelessInsights.framework
   on Mac Catalyst (and does NOT bundle it in the ios-arm64 slice).
2. The bundled WirelessInsights.framework exports every public Swift ABI symbol
   imported by iOS 26+ clients (ServicePrediction, ServicePredictionError,
   ServicePredictionProvider).
3. An end-to-end Catalyst binary that weak-links the nonexistent system path
   /System/Library/Frameworks/WirelessInsights.framework/WirelessInsights starts
   with NULL weak-import GOT slots, rebinds them via LC_DYLD_CHAINED_FIXUPS from
   the bundled WirelessInsightsCompatibility framework, keeps
   _availability_version_check(PLATFORM_IOS, 26.0.0) monotonic with iOS 27.1,
   and catches ServicePredictionError.unsupportedDevice when iterating
   ServicePredictionProvider().servicePredictions.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REQUIRED_WIRELESS_INSIGHTS_SYMBOLS = [
    "_$s16WirelessInsights17ServicePredictionV10ConfidenceO3lowyA2EmFWC",
    "_$s16WirelessInsights17ServicePredictionV10ConfidenceO4highyA2EmFWC",
    "_$s16WirelessInsights17ServicePredictionV10ConfidenceO6mediumyA2EmFWC",
    "_$s16WirelessInsights17ServicePredictionV10ConfidenceOMa",
    "_$s16WirelessInsights17ServicePredictionV15ConfidenceScoreV10predictionAC0E0Ovg",
    "_$s16WirelessInsights17ServicePredictionV15ConfidenceScoreV8durationAC0E0Ovg",
    "_$s16WirelessInsights17ServicePredictionV15ConfidenceScoreV9startTimeAC0E0Ovg",
    "_$s16WirelessInsights17ServicePredictionV15ConfidenceScoreVMa",
    "_$s16WirelessInsights17ServicePredictionV15confidenceScoreAC010ConfidenceF0Vvg",
    "_$s16WirelessInsights17ServicePredictionV17predictedIntervalSdvg",
    "_$s16WirelessInsights17ServicePredictionV18predictedStartTime10Foundation4DateVvg",
    "_$s16WirelessInsights17ServicePredictionV6ImpactO3lowyA2EmFWC",
    "_$s16WirelessInsights17ServicePredictionV6ImpactO4highyA2EmFWC",
    "_$s16WirelessInsights17ServicePredictionV6ImpactO6mediumyA2EmFWC",
    "_$s16WirelessInsights17ServicePredictionV6ImpactOMa",
    "_$s16WirelessInsights17ServicePredictionV6impactAC6ImpactOvg",
    "_$s16WirelessInsights17ServicePredictionVMa",
    "_$s16WirelessInsights22ServicePredictionErrorO010connectionE0yA2CmFWC",
    "_$s16WirelessInsights22ServicePredictionErrorO17unsupportedDeviceyA2CmFWC",
    "_$s16WirelessInsights22ServicePredictionErrorOMa",
    "_$s16WirelessInsights25ServicePredictionProviderC18servicePredictionsSci_pSayAA0cD0VG7ElementSciRts_s5Error_p7FailureSciRtsXPvg",
    "_$s16WirelessInsights25ServicePredictionProviderCACycfc",
    "_$s16WirelessInsights25ServicePredictionProviderCMa",
    "_$s16WirelessInsights25ServicePredictionProviderCMn",
]


def resolve_root() -> Path:
    here = Path(__file__).resolve()
    root = here.parent.parent.parent
    if (root / "PlayTools" / "PlayTools").is_dir():
        return root
    return Path.cwd()


def find_built_framework(root: Path) -> Path:
    candidates = [
        root / "build" / "PlayToolsCatalyst" / "Release-maccatalyst" / "PlayTools.framework",
        root / "PlayCover" / "Carthage" / "Build" / "PlayTools.xcframework" / "ios-arm64-maccatalyst" / "PlayTools.framework",
    ]
    for c in candidates:
        if (c / "PlayTools").exists():
            return c
    raise FileNotFoundError(f"Could not find built Catalyst PlayTools.framework in {candidates}")


def check_exported_symbols(wi_bin: Path) -> None:
    out = subprocess.check_output(["nm", "-gU", str(wi_bin)], text=True)
    exported = {line.split()[-1] for line in out.splitlines() if line.strip()}
    missing = [s for s in REQUIRED_WIRELESS_INSIGHTS_SYMBOLS if s not in exported]
    if missing:
        raise AssertionError(f"WirelessInsights compatibility missing {len(missing)} symbols: {missing}")
    print(f"PASS: exported-symbols ({len(REQUIRED_WIRELESS_INSIGHTS_SYMBOLS)}/{len(REQUIRED_WIRELESS_INSIGHTS_SYMBOLS)})")


def check_ios_slice_excludes_compat(root: Path) -> None:
    ios_bin = (
        root / "PlayCover" / "Carthage" / "Build" / "PlayTools.xcframework"
        / "ios-arm64" / "PlayTools.framework" / "WirelessInsightsCompatibility"
        / "WirelessInsights.framework" / "Versions" / "A" / "WirelessInsights"
    )
    if ios_bin.exists():
        raise AssertionError(f"ios-arm64 slice should not bundle WirelessInsights binary: {ios_bin}")
    print("PASS: ios-arm64-slice-clean")


def run_runtime_rebind_test(root: Path, pt_fw: Path) -> None:
    wi_src = root / "PlayTools" / "Compatibility" / "WirelessInsights.swift"
    wi_bin = pt_fw / "Resources" / "WirelessInsightsCompatibility" / "WirelessInsights.framework" / "WirelessInsights"
    if not wi_bin.exists():
        raise FileNotFoundError(f"Missing built WirelessInsights binary at {wi_bin}")

    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    tmpdir = Path(tempfile.mkdtemp(prefix="pt-wi-test-"))
    try:
        # 1. Build a temporary link-only stub dylib whose install_name is the nonexistent
        #    iOS system path /System/Library/Frameworks/WirelessInsights.framework/WirelessInsights
        #    so the Swift test binary emits genuine weak-import LC_DYLD_CHAINED_FIXUPS slots
        #    that dyld binds to NULL at launch.
        stub_dir = tmpdir / "stub"
        stub_dir.mkdir()
        stub_dylib = stub_dir / "libWirelessInsightsStub.dylib"
        stub_mod = stub_dir / "WirelessInsights.swiftmodule"
        subprocess.run([
            "xcrun", "--sdk", "macosx", "swiftc", "-O",
            "-target", "arm64-apple-ios18.0-macabi",
            "-module-name", "WirelessInsights",
            "-enable-library-evolution",
            "-emit-library",
            "-emit-module", "-emit-module-path", str(stub_mod),
            str(wi_src),
            "-o", str(stub_dylib),
            "-Xlinker", "-install_name",
            "-Xlinker", "@rpath/WirelessInsightsStub.dylib",
        ], check=True)
        subprocess.run([
            "install_name_tool", "-id",
            "/System/Library/Frameworks/WirelessInsights.framework/WirelessInsights",
            str(stub_dylib),
        ], check=True)

        # 2. Build a tiny C helper that invokes the exact PlayLoader chained-fixup rebind
        #    routine by linking PlayTools? Better: test BOTH our real PlayLoader.m runtime
        #    directly by linking the test binary against the built PlayTools.framework!
        #    Wait: linking PlayTools.framework runs PlayLoader's constructor automatically
        #    BEFORE main(), so main() can directly verify:
        #      - _availability_version_check(PLATFORM_IOS, 26.0.0) == true
        #      - _availability_version_check(PLATFORM_IOS, 27.1.0) == true
        #      - WirelessInsights.ServicePredictionProvider().servicePredictions throws .unsupportedDevice!
        test_swift = tmpdir / "main.swift"
        test_swift.write_text("""
import Foundation
import WirelessInsights

@_silgen_name("_availability_version_check")
func availabilityVersionCheck(_ count: UInt32, _ versions: UnsafePointer<UInt32>) -> Bool

@main
struct Runner {
    static func main() async {
        // 1. Verify monotonic iOS 26.0 & iOS 27.1 availability checks
        let v26: [UInt32] = [2, 0x001a0000]
        let v27_1: [UInt32] = [2, 0x001b0100]
        let ok26 = v26.withUnsafeBufferPointer { availabilityVersionCheck(1, $0.baseAddress!) }
        let ok27 = v27_1.withUnsafeBufferPointer { availabilityVersionCheck(1, $0.baseAddress!) }
        guard ok26 && ok27 else {
            fputs("FAIL: non-monotonic availability ok26=\\(ok26) ok27=\\(ok27)\\n", stderr)
            exit(1)
        }

        // 2. Verify weak-linked WirelessInsights symbols were rebound and behave cleanly
        let provider = ServicePredictionProvider()
        do {
            for try await _ in provider.servicePredictions {
                fputs("FAIL: expected unsupportedDevice error, got element\\n", stderr)
                exit(2)
            }
            fputs("FAIL: expected unsupportedDevice error, stream ended cleanly\\n", stderr)
            exit(3)
        } catch let err as ServicePredictionError {
            guard err == .unsupportedDevice else {
                fputs("FAIL: unexpected ServicePredictionError \\(err)\\n", stderr)
                exit(4)
            }
            print("RUNTIME_WI_COMPAT_OK")
        } catch {
            fputs("FAIL: unexpected error type \\(error)\\n", stderr)
            exit(5)
        }
    }
}
""", encoding="utf-8")

        test_bin = tmpdir / "wi_compat_runner"
        pt_parent = pt_fw.parent
        subprocess.run([
            "xcrun", "--sdk", "macosx", "swiftc",
            "-target", "arm64-apple-ios18.0-macabi",
            "-sdk", sdk,
            "-I", str(stub_dir),
            "-F", str(pt_parent),
            "-framework", "PlayTools",
            "-Xlinker", "-weak_library", "-Xlinker", str(stub_dylib),
            "-Xlinker", "-rpath", "-Xlinker", str(pt_parent),
            "-parse-as-library",
            str(test_swift),
            "-o", str(test_bin),
        ], check=True)

        # Verify the compiled runner truly weak-links the nonexistent system path
        otool_out = subprocess.check_output(["otool", "-L", str(test_bin)], text=True)
        if "/System/Library/Frameworks/WirelessInsights.framework/WirelessInsights" not in otool_out or "weak" not in otool_out:
            raise AssertionError(f"Expected weak link to WirelessInsights in runner:\n{otool_out}")

        # Remove stub_dylib so it cannot possibly be loaded accidentally
        stub_dylib.unlink()

        res = subprocess.run([str(test_bin)], capture_output=True, text=True, check=False, timeout=20)
        if res.returncode != 0 or "RUNTIME_WI_COMPAT_OK" not in res.stdout:
            raise AssertionError(
                f"Runtime weak-rebind test failed (rc={res.returncode}):\nstdout:\n{res.stdout}\nstderr:\n{res.stderr}"
            )
        print("PASS: runtime-weak-rebind-and-monotonic-availability")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def main() -> int:
    root = resolve_root()
    pt_fw = find_built_framework(root)
    wi_bin = pt_fw / "Resources" / "WirelessInsightsCompatibility" / "WirelessInsights.framework" / "WirelessInsights"
    if not wi_bin.exists():
        print(f"FAIL: missing {wi_bin}", file=sys.stderr)
        return 1
    check_exported_symbols(wi_bin)
    check_ios_slice_excludes_compat(root)
    run_runtime_rebind_test(root, pt_fw)
    print("ALL WirelessInsights compatibility checks PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
