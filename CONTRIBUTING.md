# Contributing to OpenSnapX

Thank you for helping build a fast, native, open screenshot tool for macOS.

## Ground rules

- Contributions are licensed under GPL-3.0.
- Keep runtime behavior local-first and do not add telemetry or implicit network access.
- Use public macOS APIs and preserve the macOS 14 deployment target.
- Prefer AppKit and Apple frameworks over third-party dependencies.
- Never silently change privacy, keyboard, or security settings.

## Development

1. Install Xcode 16+ and XcodeGen.
2. Run `./script/build_and_run.sh`.
3. Add or update tests for behavior changes.
4. Run the full `xcodebuild test` command from the README.

The generated Xcode project is checked in for contributor convenience, but `project.yml` is authoritative.

## Pull requests

Keep changes focused. Describe user-visible behavior, permissions affected, manual verification performed, and any data retained on disk. UI work should be checked in light/dark mode, with VoiceOver labels, and across Retina/non-Retina or multi-display setups when relevant.

