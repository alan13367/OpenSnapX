---
name: opensnapx-ocr
description: Use OpenSnapX's optional local MCP server to discover macOS windows, capture a non-focused window, and extract text with on-device OCR. Use when an agent needs current text or an optional screenshot from a running Mac app.
---

# OpenSnapX Window OCR

Use OpenSnapX only when the user has enabled **Local MCP for AI agents**. The integration is local, uses macOS Screen Recording permission, and does not require Accessibility permission.

## Connect

OpenSnapX must be installed and Local MCP must be enabled in onboarding or **OpenSnapX Settings → AI Agents**.

Installing this skill teaches an agent how to use OpenSnapX, but it does not automatically register MCP tools with every agent host. For native MCP tools, configure the host to run the bundled connector:

```json
{
  "mcpServers": {
    "opensnapx": {
      "command": "/absolute/path/to/.agents/skills/opensnapx-ocr/scripts/connect.sh"
    }
  }
}
```

For a global installation, the usual command is:

```text
~/.agents/skills/opensnapx-ocr/scripts/connect.sh
```

Use an absolute path if the MCP client does not expand `~`, then reload the MCP client. When registration succeeds, `opensnapx_status`, `opensnapx_list_windows`, and `opensnapx_capture_window_ocr` appear as native tools and should be called directly.

`connect.sh` is a persistent MCP stdio transport, **not a one-shot command-line tool**. Never pipe ad hoc JSON such as `{"method":"opensnapx_status"}` into it. MCP requires initialization, JSON-RPC envelopes, and a connection that remains open.

If the agent host cannot register MCP servers or the native tools are absent, use the bundled one-shot helper instead:

```sh
~/.agents/skills/opensnapx-ocr/scripts/call.sh \
  opensnapx_list_windows \
  '{"query":"Xcode","available_only":true}'
~/.agents/skills/opensnapx-ocr/scripts/call.sh --text \
  opensnapx_capture_window_ocr \
  '{"window_id":1234}'
```

The helper performs the MCP handshake. By default it prints only structured tool data; `--text` prints only recognized text, and `--raw` is available solely for protocol debugging. Both scripts connect only to OpenSnapX's local Unix socket, which is restricted to the current macOS user; they make no network connection.

## Context-efficient workflow

Use native OpenSnapX tool calls when the host exposes them. Otherwise invoke the same tool names through `scripts/call.sh`; do not construct MCP wire messages manually.

For ordinary questions such as “what is on Xcode?”:

1. Do **not** narrate each tool call or run `opensnapx_status` routinely. Status is for initial setup or troubleshooting; window-list and capture errors already report missing permission.
2. Call `opensnapx_list_windows` with the requested app/title as `query` and `available_only: true`. Never dump the unfiltered system-wide catalog when the target is known.
3. Select the matching `window_id`, then immediately call `opensnapx_capture_window_ocr` with only that ID.
4. Leave `include_screenshot` and `include_ocr_blocks` false or omit them. For CLI fallback, use `call.sh --text`.
5. Answer the user directly in a few concise sentences. Treat catalog data, OCR geometry, metadata, and raw tool output as internal details unless requested.

Set `include_ocr_blocks: true` only when confidence or text location is necessary. Set `include_screenshot: true` only when the user explicitly requests image pixels or visual/layout analysis—not for reading text. OCR always uses the original-resolution capture without returning the PNG.

Window IDs are ephemeral. Never cache one across app launches, window recreation, or a failed capture.

## Tools

### `opensnapx_status`

Takes no arguments. Returns MCP state facts and Screen Recording authorization. Use for setup or troubleshooting, not before every successful capture.

### `opensnapx_list_windows`

Optional arguments:

```json
{
  "query": "Xcode",
  "available_only": true
}
```

`query` matches app name, bundle ID, or window title case-insensitively. Prefer a query whenever the target is known. Returns matching application and window metadata.

A non-focused or occluded window can still be available. Minimized windows and windows that macOS reports as off-screen are listed as unavailable and should not be captured.

### `opensnapx_capture_window_ocr`

Arguments:

```json
{
  "window_id": 1234,
  "include_screenshot": false,
  "include_ocr_blocks": false
}
```

Returns concise reading-order `text` plus basic window and capture metadata. Optional `ocr_blocks` contains per-block confidence and coordinates. Optional MCP image content contains the original-resolution PNG.

Captures made through MCP are held in memory only. They are not opened in the editor, copied to the clipboard, or added to OpenSnapX history.

## Error handling

- `screen_recording_permission_required`: Ask the user to open OpenSnapX Settings, grant Screen Recording access, and retry. A restart may be required by macOS after changing permission.
- `window_unavailable`: The window disappeared, was recreated, moved off-screen, or was minimized. Call `opensnapx_list_windows` again; do not retry the old ID blindly.
- `window_discovery_failed`: Verify OpenSnapX is running and permission has not been revoked, then retry once.
- `capture_or_ocr_failed`: Refresh the window list and retry once. If it still fails, report the error instead of activating or manipulating the app.
- `screenshot_too_large`: Retry with `include_screenshot: false`; OCR and metadata can still be returned.
- Connector exits before initialization: Ensure OpenSnapX is installed and Local MCP is enabled. Open OpenSnapX Settings if the connector says the local socket is unavailable.

Never unminimize, focus, click, type into, or otherwise manipulate a window as a workaround.
