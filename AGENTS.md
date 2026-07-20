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
| Optional MCP | Local Unix-domain socket only; off by default |

## Layout

```
OpenSnapX/
  App/          # AppDelegate, AppCoordinator (orchestration, MCP lifecycle)
  UI/           # Window/panel controllers + custom NSViews
    Editor/      # Editor orchestration, toolbar, canvas, renderer, geometry, panels
  Services/     # Capture, history, OCR, export, shortcuts, settings, MCP, skill install
  Models/       # Codable domain types + MCP JSON/tool models
  Support/      # Geometry, color, image codec helpers
  Resources/    # Info.plist, entitlements, assets
.agents/skills/opensnapx-ocr/  # Bundled agent skill (SKILL.md + connect/call scripts)
OpenSnapXTests/ # XCTest unit tests for services/models (incl. MCPTests)
project.yml     # Authoritative XcodeGen source — never hand-edit pbxproj
script/         # build.sh, build_and_run.sh
```

`project.yml` copies `.agents/skills/opensnapx-ocr` into the app bundle as a folder resource. Edit the skill in-repo; do not maintain a second copy under `Resources/`.

## Architecture rules

- **UI on `@MainActor`.** Controllers and AppKit types stay main-actor; heavy work goes through `Sendable` service protocols.
- **Protocol + concrete impl.** Prefer `any CaptureService`, `any HistoryStore`, `any MCPServer`, `any MCPToolHandling`, etc., so logic stays testable without UI.
- **Coordinator owns flow.** `AppCoordinator` wires shortcuts, overlays, editor, history, permissions, and MCP start/stop/status. Don’t scatter capture or MCP lifecycle across unrelated controllers.
- **Editor boundaries.** Under `UI/Editor`, `EditorWindowController` orchestrates session/services/undo; `EditorToolbarController` emits value-typed commands; `EditorCanvasView` owns input and annotation mutation; `EditorCanvasRenderer` only draws previews; `AnnotationCanvasGeometry` contains deterministic geometry. Keep resize, backdrop, and text-formatting UI in their existing subcomponents rather than growing the window controller or canvas renderer.
- **History packages.** Editable captures are atomic `.opensnapx` directories (manifest + source PNG + annotations + optional OCR + thumbnail). Preserve that format when changing persistence.
- **Sandbox.** App is sandboxed; only user-selected file read/write beyond the container. No network entitlements. Local MCP uses a Unix socket under the container temp dir plus a user-readable pointer file — not TCP.
- **Capture split.** Interactive capture uses `CaptureService`. Agent window capture uses `WindowCaptureService` (`ScreenCaptureService` implements both). MCP must not activate, focus, unminimize, or control other apps.

## Optional local MCP

Opt-in via Settings/onboarding (`SettingsStore.mcpEnabled`, default `false`). When enabled:

| Piece | Role |
|-------|------|
| `UnixSocketMCPServer` | Listen/accept, status, pointer file |
| `MCPProtocol` | JSON-RPC / MCP framing |
| `MCPToolService` | Tool schemas + handlers |
| `LocalAgentSkillInstaller` | User-prompted skill install (NSOpenPanel) |

**Tools:** `opensnapx_status`, `opensnapx_list_windows`, `opensnapx_capture_window_ocr`.

**Socket discovery:** pointer at  
`~/Library/Containers/io.github.alan13367.OpenSnapX/Data/Library/Application Support/OpenSnapX/MCP/socket-path`  
(mode `0600`). Clients (`connect.sh` / `call.sh`) read that path; they never open a network port.

**Invariants (do not break):**

- MCP captures are in-memory only — never editor, clipboard, or history.
- OCR always on original-resolution capture; PNG returned only if `include_screenshot: true`.
- No Accessibility permission; Screen Recording only.
- While enabled, any process as the current macOS user can connect — no per-agent ACL, no per-request confirmation. Surface enabled/active state in the menu bar.
- Skill install and MCP client config edits require explicit user action; never silently rewrite host MCP config.
- Keep `PRIVACY.md`, Settings/onboarding copy, and `NSScreenCaptureUsageDescription` aligned when any of the above changes.

Agent-facing usage docs live in `.agents/skills/opensnapx-ocr/SKILL.md` — keep tool names/args and the context-efficient defaults in sync when changing `MCPToolService`.

## Non-negotiables

- No analytics, telemetry, accounts, cloud upload, or Internet requests (local Unix MCP ≠ network).
- No silent changes to privacy, keyboard, or security system settings.
- Prefer Apple frameworks over SPM/CocoaPods dependencies.
- Do not add Mac App Store targets, video/GIF recording, automatic scrolling, or translation — those are out of v1 scope (see README). User-guided scrolling capture already exists; do not turn it into unattended auto-scroll.
- If privacy/retention/MCP access behavior changes, update `PRIVACY.md` and in-app copy in the same change.

## Coding conventions

- Match existing style: `final class` for controllers, `struct` for models/engines, explicit `Sendable` where needed.
- Keep annotation rendering non-destructive until export/flatten; undo/redo and history must remain coherent.
- Use `Logger` (OSLog) for diagnostics — no `print` spam in shipping paths.
- Accessibility: give VoiceOver-relevant controls labels/descriptions when adding UI.
- UI changes: consider light/dark mode and multi-display / Retina when relevant.

## Build & test

```sh
./script/build.sh              # regenerate project if needed, build
./script/build_and_run.sh     # build, stop existing process, open
./script/build_and_run.sh --verify # build, launch, confirm process is alive

xcodegen generate                  # after editing project.yml
xcodebuild test \
  -project OpenSnapX.xcodeproj \
  -scheme OpenSnapX \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Add or update `OpenSnapXTests` for service/model behavior changes (MCP protocol/tools included). Prefer testing engines and stores over AppKit controllers.

## Agent workflow

1. Read nearby code before changing patterns; extend protocols instead of bypassing them.
2. After `project.yml` edits or adding/moving source files, run `xcodegen generate`.
3. Run `xcodebuild test` (above) for logic changes; use `./script/build_and_run.sh` when you need a live UI check.
4. Keep diffs focused; don’t refactor unrelated files or expand v1 scope unprompted.
5. MCP/skill changes: update `MCPTests`, bundled `SKILL.md`/scripts, and privacy/UI copy together when behavior or tool contracts change.
