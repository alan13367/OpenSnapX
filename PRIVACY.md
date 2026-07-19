# OpenSnapX Privacy

OpenSnapX is local-first by design:

- It does not contain analytics, telemetry, advertising, accounts, cloud upload code, or Internet requests.
- Screen contents are read only after macOS grants Screen Recording access and either the user starts a capture or a local MCP client makes a request after the user enables agent access.
- The optional MCP server is disabled by default. It communicates through a local Unix domain socket restricted to the current macOS user, not a TCP network listener, and its enabled/active state is visible in the OpenSnapX menu-bar menu.
- While MCP is enabled, any process running as the current macOS user can connect to that socket and request the exposed capture and OCR tools; access is not limited to a particular agent application and requests do not require per-request confirmation.
- MCP access does not require Accessibility permission. OpenSnapX does not focus, unminimize, click, type into, or otherwise control other applications for MCP capture.
- OCR uses Apple's Vision framework on the Mac at the capture's original resolution.
- Image captures created through normal OpenSnapX workflows are stored in the app container under Application Support for seven days by default, including captures configured to copy to the clipboard or remain in History without opening the editor. Retention can be changed or disabled in Settings.
- Capture Text images are processed in memory for OCR and are never added to history or otherwise retained by OpenSnapX. Recognized text is copied immediately or shown in an editable review window according to the action selected in Settings, then released when that flow ends.
- MCP captures and OCR are processed in memory and are not added to OpenSnapX history. Screenshot bytes are encoded only when the requesting agent explicitly asks for the image and are released after the response.
- A redacted export is flattened, but the original source from a normal capture remains in editable history until that entry is deleted or expires.
- Clipboard writes happen only after the user starts a capture configured to copy its result or presses a copy control. Saving and sharing happen only through an explicit save, drag-and-drop, or system Share sheet action.
- Installing the optional agent skill requires an explicit user action and a macOS file-selection prompt. OpenSnapX does not silently edit agent or MCP client configuration.

If future functionality changes any of these properties, this document and the in-app explanation must change before release.
