# PlayTools

PlayTools is the runtime framework bundled with [PlayCover](https://github.com/Rengwang/PlayCover). It provides adaptive windows, keyboard and controller mapping, input translation, and PlayChain compatibility for installed iOS apps.

## Build and test

In the paired local workspace, run `./sync_upstream.sh build` from the directory containing both repositories. The script builds separate arm64 iOS and Mac Catalyst slices and packages the AppKit bridge, `AKInterface.bundle`, into both. PlayCover selects the slice appropriate for the installation target.

See the [maintenance guide](https://github.com/Rengwang/PlayCover/blob/develop/SESSION_MODIFICATIONS.md) for build outputs, upstream synchronization, and opt-in runtime diagnostics.

## Components

- **PlayTools** runs inside the installed application and handles UIKit geometry, input, and PlayChain.
- **AKInterface** provides the macOS window, input, and cursor bridge.
- **PlayTools.strings** is copied under its own name so the runtime and the application can each load their localized strings.
