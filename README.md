# OpenSnapX

<p align="center">
  <img src="assets/OpenSnapXAppIcon.png" alt="OpenSnapX icon" width="128">
</p>

OpenSnapX is a native, local-first screenshot and annotation utility for macOS. It is built with Swift 6 and AppKit—no Electron, Qt, accounts, telemetry, or cloud service.

> **Work in progress.** OpenSnapX is not fully functional yet. Build it locally, expect incomplete features and rough edges, and please report reproducible bugs.

## What works

- Area, window, display, scrolling, and text capture
- Multi-display overlays with dimensions, keyboard adjustment, and window snapping
- ScreenCaptureKit still capture with on-device Vision OCR
- Configurable post-capture actions for opening the editor, copying immediately, or keeping image captures in History
- Editable OCR review before copying text, with Capture Text images processed in memory and never retained
- Clipboard, PNG/JPEG save, and the macOS Share sheet
- Seven-day local editable image history with automatic cleanup
- Non-destructive arrows, lines, shapes, text, pen, highlight, counters, blur, pixelate, solid redaction, and crop
- Undo/redo, zoom, non-destructive image resizing, annotation movement/duplication, pinned images, and focused backdrop styling
- User-guided scrolling capture with local overlap validation and stitching
- Menu-bar operation and global screenshot shortcuts without Accessibility permission
- Optional, disabled-by-default local MCP window OCR for AI agents

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

The script regenerates the Xcode project when needed, stops an existing OpenSnapX process, and opens the result. When an Apple Development certificate is available it signs with that stable identity so macOS privacy grants survive rebuilds; otherwise it falls back to ad-hoc signing. Set `OPEN_SNAPX_AD_HOC_SIGN=1` to force the fallback. `--verify`, `--debug`, `--logs`, and `--telemetry` modes are also available.

For Xcode Run builds, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`, replace `YOUR_TEAM_ID`, then run `xcodegen generate`. The local file is ignored by Git. Stable development signing matters because macOS ties Screen Recording permission to the app's code identity, and an ad-hoc identity changes after rebuilds.

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
2. Assign capture shortcuts during onboarding or later in **OpenSnapX Settings**. macOS does not let third-party apps override its built-in screenshot actions, so if you keep `⌘⇧3`, `⌘⇧4`, or `⌘⇧5`, open **System Settings → Keyboard → Keyboard Shortcuts → Screenshots** and turn off the matching Apple shortcuts. OpenSnapX never changes system preferences for you.
3. With those Apple shortcuts turned off, use `⌘⇧3` for a display, `⌘⇧4` for an area/window, `⌘⇧5` for scrolling capture, and `⌘⇧2` for direct OCR. You can instead record conflict-free combinations in OpenSnapX.
4. Optional: enable **Local MCP for AI agents** during onboarding or later in Settings. It remains off unless you explicitly enable it.

Locally rebuilt ad-hoc-signed apps can cause macOS to request Screen Recording permission again. The build script avoids that when a local Apple Development certificate is installed. Signed and notarized downloadable builds require a future Apple Developer Program membership.

## Optional local MCP

OpenSnapX can expose three local MCP tools to AI agents:

- `opensnapx_status`
- `opensnapx_list_windows`
- `opensnapx_capture_window_ocr`

The MCP server is disabled by default. When enabled, its state appears as a separate item in the existing OpenSnapX menu-bar menu. Agent requests run unattended, but active requests are shown there. ScreenCaptureKit captures non-focused and occluded windows without activating them; minimized or otherwise off-screen windows are listed as unavailable.

Communication uses a Unix domain socket restricted to the current macOS user and a stdio connector—no TCP listener or Internet access. While MCP is enabled, any process running as that user can connect and invoke the exposed tools; access is not restricted to a particular configured agent, and requests do not require per-request confirmation. OCR always runs on the original-resolution capture. Screenshots are returned only when the client explicitly requests one, remain at original resolution, and are never added to OpenSnapX history.

Use **Settings → AI Agents → Install Agent Skill…** to install `.agents/skills/opensnapx-ocr` globally (the default) or in a selected project. OpenSnapX asks before writing outside its sandbox and does not silently edit MCP client configuration. The installed skill documents a context-efficient workflow: filter window discovery by app/title, return OCR text without block geometry by default, and request PNG data only for explicit visual analysis. MCP-capable hosts should register `scripts/connect.sh`; agents without native MCP registration can use the concise `scripts/call.sh` one-shot helper.

Only Screen Recording permission is required. Accessibility permission is not requested because OpenSnapX does not focus, unminimize, or control other apps.

## Architecture

The application is sandboxed and dependency-free at runtime. UI is isolated to the main actor; capture, rendering, OCR, persistence, and scrolling behavior sit behind testable service interfaces. History entries are atomic internal `.opensnapx` packages containing a versioned manifest, source PNG, annotation JSON, optional OCR data, and a thumbnail.

The Xcode project is generated from `project.yml`. Edit that source file and run `xcodegen generate`; do not hand-edit `project.pbxproj`.

## Privacy and security

OpenSnapX makes no network requests. Captures and OCR remain on the Mac. Editable source images created by normal image-capture workflows are retained for seven days by default—even after an exported image has been redacted—unless the history entry is deleted sooner. Capture Text and MCP images are processed in memory and are not retained by OpenSnapX. See [PRIVACY.md](PRIVACY.md).

## Contributing

Contributions and bug reports are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

Copyright © 2026 OpenSnapX contributors. OpenSnapX is free software licensed under the GNU General Public License, version 3. Direct GitHub/website distribution is the intended release channel; the Mac App Store is not a project target. See [LICENSE](LICENSE).
