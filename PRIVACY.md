# OpenSnapX Privacy

OpenSnapX is local-first by design:

- It does not contain analytics, telemetry, advertising, accounts, cloud upload code, or network requests.
- Screen contents are read only after a user invokes a capture workflow and macOS grants Screen Recording access.
- OCR uses Apple's Vision framework on the Mac.
- Captures are stored in the app container under Application Support for seven days by default. Retention can be changed or disabled in Settings.
- A redacted export is flattened, but the original source remains in editable history until that entry is deleted or expires.
- Saving and sharing happen only after an explicit user action through the clipboard, a save panel, drag-and-drop, or the system Share sheet.

If future functionality changes any of these properties, this document and the in-app explanation must change before release.

