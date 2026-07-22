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
  '{"query":"Xcode"}'
~/.agents/skills/opensnapx-ocr/scripts/call.sh --text \
  opensnapx_capture_window_ocr \
  '{"query":"Xcode"}'
~/.agents/skills/opensnapx-ocr/scripts/call.sh --text \
  opensnapx_capture_window_ocr \
  '{"bundle_id":"com.apple.dt.Xcode","query":"MyProject","region":{"x":0,"y":0,"width":1,"height":0.6}}'
```

The helper performs the MCP handshake. By default it prints only structured tool data; `--text` prints only recognized text, and `--raw` is available solely for protocol debugging. Both scripts connect only to OpenSnapX's local Unix socket, which is restricted to the current macOS user; they make no network connection.

## Context-efficient workflow

Use native OpenSnapX tool calls when the host exposes them. Otherwise invoke the same tool names through `scripts/call.sh`; do not construct MCP wire messages manually.

For ordinary questions such as “what is on Xcode?”:

1. Do **not** narrate each tool call or run `opensnapx_status` routinely. Status is for initial setup or troubleshooting; window-list and capture errors already report missing permission.
2. Prefer calling `opensnapx_capture_window_ocr` directly with the requested app/title as `query`, adding an exact `bundle_id` when known. The tool captures only a unique best match and never guesses when matches are ambiguous.
3. If targeting is ambiguous, inspect `candidate_window_ids` or call `opensnapx_list_windows` with a query, then retry immediately with a more specific query, bundle ID, or selected `window_id`.
4. Leave `include_screenshot`, `include_ocr_blocks`, and `region` false/omitted unless needed. For CLI fallback, use `call.sh --text`.
5. Answer the user directly in a few concise sentences. Treat catalog data, OCR geometry, metadata, and raw tool output as internal details unless requested.

Set `include_ocr_blocks: true` only when confidence or text location is necessary. Set `include_screenshot: true` only when the user explicitly requests image pixels or visual/layout analysis—not for reading text. Use `region` when a stable portion of the window contains the relevant text and full-window OCR would add noise. OCR always uses original-resolution pixels without returning the PNG by default.

Window IDs are ephemeral. Never cache one across app launches, window recreation, or a failed capture.

## Tools

### `opensnapx_status`

Takes no arguments. Returns MCP state facts and Screen Recording authorization. Use for setup or troubleshooting, not before every successful capture.

### `opensnapx_list_windows`

Optional arguments:

```json
{
  "query": "Xcode",
  "available_only": true,
  "limit": 50
}
```

`query` matches app name, bundle ID, or window title case-insensitively. `available_only` defaults to `true`; set it to `false` only when diagnosing an unavailable window. `limit` defaults to 50 and accepts 1–200. Results always include `returned_count`, `matched_count`, and `truncated`.

A non-focused or occluded window can still be available. Minimized windows and windows that macOS reports as off-screen are listed as unavailable and should not be captured.

### `opensnapx_capture_window_ocr`

Arguments:

```json
{
  "query": "MyProject",
  "bundle_id": "com.apple.dt.Xcode",
  "include_screenshot": false,
  "include_ocr_blocks": false,
  "region": { "x": 0, "y": 0, "width": 1, "height": 0.6 }
}
```

Target with either `window_id`, or with `query` and/or exact `bundle_id`; never combine `window_id` with query targeting. Query matching considers capturable windows only, favors an exact title over title/app substrings, and returns `ambiguous_window` rather than guessing when the best match is tied. Ambiguity details return at most 50 candidates and report `returned_candidate_count`, `matched_candidate_count`, and `candidates_truncated`; use filtered window listing when more refinement is needed.

`region` is optional and uses top-left-origin normalized window-image coordinates in `[0,1]`. OpenSnapX crops original-resolution pixels before OCR and optional PNG encoding. Returned OCR block coordinates are relative to the cropped image, and capture metadata reports the pixel-aligned applied region and cropped dimensions.

Returns concise reading-order `text` plus basic window and capture metadata. Optional `ocr_blocks` contains per-block confidence and coordinates. Optional MCP image content contains the full window or selected region at original pixel density.

Captures made through MCP are held in memory only. They are not opened in the editor, copied to the clipboard, or added to OpenSnapX history.

## Error handling

- `screen_recording_permission_required`: Ask the user to open OpenSnapX Settings, grant Screen Recording access, and retry. A restart may be required by macOS after changing permission.
- `ambiguous_window`: Do not guess. Refine `query`/`bundle_id` or select one of the returned candidate window IDs. If `candidates_truncated` is true, use a filtered `opensnapx_list_windows` call rather than requesting an unbounded catalog.
- `window_unavailable`: The window disappeared, was recreated, moved off-screen, or was minimized. Call `opensnapx_list_windows` again; do not retry the old ID blindly.
- `invalid_arguments`: Correct the targeting mode or normalized region; do not combine `window_id` with query targeting.
- `window_discovery_failed`: Verify OpenSnapX is running and permission has not been revoked, then retry once.
- `capture_or_ocr_failed`: Refresh the window list and retry once. If it still fails, report the error instead of activating or manipulating the app.
- `screenshot_too_large`: Retry with `include_screenshot: false`; OCR and metadata can still be returned.
- Connector says OpenSnapX is not installed or launchable: Install/open the app, then retry.
- Connector says Local MCP is disabled: Open **Settings → AI Agents** and enable it.
- Connector reports a stale or unreachable socket: Quit and reopen OpenSnapX with Local MCP enabled.

Never unminimize, focus, click, type into, or otherwise manipulate a window as a workaround.
