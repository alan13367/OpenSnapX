# OpenSnapX

Native macOS screenshot & annotation tool (Shottr-inspired). Swift 6 + AppKit only — no Qt, Electron, SwiftUI, or third-party runtime deps. Local-first, always free, GPL-3.0.

## Stack

| Item | Value |
|------|--------|
| Language | Swift 6.0 (`SWIFT_STRICT_CONCURRENCY: targeted`) |
| UI | AppKit, windows/views built in code (storyboard is app entry + menu only) |
| Capture / OCR | ScreenCaptureKit, Vision |
| Min OS | macOS 14.0+ |
| Bundle ID | `io.github.alan13367.OpenSnapX` |
| Menu bar | `LSUIElement` accessory app |

## Layout

```
OpenSnapX/
  App/          # AppDelegate, AppCoordinator (orchestration)
  UI/           # Window/panel controllers + custom NSViews
  Services/     # Capture, history, OCR, export, shortcuts, settings
  Models/       # Codable domain types (sessions, annotations)
  Support/      # Geometry, color, image codec helpers
  Resources/    # Info.plist, entitlements, assets
OpenSnapXTests/ # XCTest unit tests for services/models
project.yml     # Authoritative XcodeGen source — never hand-edit pbxproj
script/         # build_and_run.sh
```

## Architecture rules

- **UI on `@MainActor`.** Controllers and AppKit types stay main-actor; heavy work goes through `Sendable` service protocols.
- **Protocol + concrete impl.** Prefer `any CaptureService`, `any HistoryStore`, etc., so logic stays testable without UI.
- **Coordinator owns flow.** `AppCoordinator` wires shortcuts, overlays, preview, editor, history, and permissions. Don’t scatter capture lifecycle across unrelated controllers.
- **History packages.** Editable captures are atomic `.opensnapx` directories (manifest + source PNG + annotations + optional OCR + thumbnail). Preserve that format when changing persistence.
- **Sandbox.** App is sandboxed; only user-selected file read/write beyond the container. No network entitlements.

## Non-negotiables

- No analytics, telemetry, accounts, cloud upload, or network requests.
- No silent changes to privacy, keyboard, or security system settings.
- Prefer Apple frameworks over SPM/CocoaPods dependencies.
- Do not add Mac App Store targets, video/GIF recording, automatic scrolling, or translation — those are out of v1 scope (see README).
- If privacy/retention behavior changes, update `PRIVACY.md` and in-app copy in the same change.

## Coding conventions

- Match existing style: `final class` for controllers, `struct` for models/engines, explicit `Sendable` where needed.
- Keep annotation rendering non-destructive until export/flatten; undo/redo and history must remain coherent.
- Use `Logger` (OSLog) for diagnostics — no `print` spam in shipping paths.
- Accessibility: give VoiceOver-relevant controls labels/descriptions when adding UI.
- UI changes: consider light/dark mode and multi-display / Retina when relevant.

## Build & test

```sh
./script/build_and_run.sh          # regenerate project if needed, build, open
./script/build_and_run.sh --verify # build, launch, confirm process is alive

xcodegen generate                  # after editing project.yml
xcodebuild test \
  -project OpenSnapX.xcodeproj \
  -scheme OpenSnapX \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Add or update `OpenSnapXTests` for service/model behavior changes. Prefer testing engines and stores over AppKit controllers.

## Agent workflow

1. Read nearby code before changing patterns; extend protocols instead of bypassing them.
2. After `project.yml` edits, run `xcodegen generate`.
3. Run `xcodebuild test` (above) for logic changes; use `./script/build_and_run.sh` when you need a live UI check.
4. Keep diffs focused; don’t refactor unrelated files or expand v1 scope unprompted.
