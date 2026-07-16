# OpenSnapX

OpenSnapX is a native, local-first screenshot and annotation utility for macOS. It is built with Swift 6 and AppKit—no Electron, Qt, accounts, telemetry, or cloud service.

> OpenSnapX is an early source preview. Build it locally, expect rough edges, and please report reproducible bugs.

## What works

- Area, window, display, delayed, scrolling, and text capture
- Multi-display overlays with dimensions, keyboard adjustment, and window snapping
- ScreenCaptureKit still capture with on-device Vision OCR
- Floating quick-action preview, clipboard, PNG/JPEG save, drag-and-drop, and the macOS Share sheet
- Seven-day local editable history with automatic cleanup
- Non-destructive arrows, lines, shapes, text, pen, highlight, counters, blur, pixelate, solid redaction, and crop
- Undo/redo, zoom, annotation movement/duplication, pinned images, and focused backdrop styling
- User-guided scrolling capture with local overlap validation and stitching
- Menu-bar operation and global screenshot shortcuts without Accessibility permission

Video/GIF recording, audio, cloud uploads, automatic scrolling, translation, and multi-image composition are intentionally outside v1.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later with Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the checked-in Xcode project after changing `project.yml`

## Build and run

```sh
brew install xcodegen
./script/build_and_run.sh
```

The script regenerates the Xcode project when needed, stops an existing OpenSnapX process, builds a local ad-hoc-signed app, and opens the result. `--verify`, `--debug`, `--logs`, and `--telemetry` modes are also available.

To run tests directly:

```sh
xcodegen generate
xcodebuild test \
  -project OpenSnapX.xcodeproj \
  -scheme OpenSnapX \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

## First run

1. Grant Screen Recording access when prompted. OpenSnapX cannot capture without macOS consent.
2. Assign capture shortcuts during onboarding or later in **OpenSnapX Settings**. To use Apple’s familiar combinations, disable the matching entries in **System Settings → Keyboard → Keyboard Shortcuts → Screenshots** first. OpenSnapX reports conflicts and never changes system preferences itself.
3. Use `⌘⇧3` for a display, `⌘⇧4` for an area/window, `⌘⇧5` for the palette, and `⌘⇧2` for direct OCR.

Locally rebuilt ad-hoc-signed apps can cause macOS to request Screen Recording permission again. Signed and notarized downloadable builds require a future Apple Developer Program membership.

## Architecture

The application is sandboxed and dependency-free at runtime. UI is isolated to the main actor; capture, rendering, OCR, persistence, and scrolling behavior sit behind testable service interfaces. History entries are atomic internal `.opensnapx` packages containing a versioned manifest, source PNG, annotation JSON, optional OCR data, and a thumbnail.

The Xcode project is generated from `project.yml`. Edit that source file and run `xcodegen generate`; do not hand-edit `project.pbxproj`.

## Privacy and security

OpenSnapX makes no network requests. Captures and OCR remain on the Mac. Editable source images are retained for seven days by default—even after an exported image has been redacted—unless the history entry is deleted sooner. See [PRIVACY.md](PRIVACY.md).

## Contributing

Contributions and bug reports are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

Copyright © 2026 OpenSnapX contributors. OpenSnapX is free software licensed under the GNU General Public License, version 3. Direct GitHub/website distribution is the intended release channel; the Mac App Store is not a project target. See [LICENSE](LICENSE).
