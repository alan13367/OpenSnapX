#!/bin/sh
set -eu

BUNDLE_ID="io.github.alan13367.OpenSnapX"
POINTER="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/OpenSnapX/MCP/socket-path"

socket_is_ready() {
    [ -r "$POINTER" ] || return 1
    SOCKET_PATH="$(/bin/cat "$POINTER")"
    [ -n "$SOCKET_PATH" ] && [ -S "$SOCKET_PATH" ]
}

if ! socket_is_ready; then
    /usr/bin/open -gj -b "$BUNDLE_ID" >/dev/null 2>&1 || true
    attempts=0
    while [ "$attempts" -lt 50 ]; do
        if socket_is_ready; then
            break
        fi
        attempts=$((attempts + 1))
        /bin/sleep 0.1
    done
fi

if ! socket_is_ready; then
    echo "OpenSnapX Local MCP is unavailable. Open OpenSnapX Settings and enable Local MCP for AI agents." >&2
    exit 1
fi

WORK_DIRECTORY=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/opensnapx-mcp-connect.XXXXXX")
INPUT_FIFO="$WORK_DIRECTORY/input"
INPUT_CLOSED="$WORK_DIRECTORY/input-closed"
TRANSPORT_PID=""
INPUT_PID=""

cleanup() {
    if [ -n "$INPUT_PID" ] && /bin/kill -0 "$INPUT_PID" 2>/dev/null; then
        /bin/kill "$INPUT_PID" 2>/dev/null || true
    fi
    if [ -n "$TRANSPORT_PID" ] && /bin/kill -0 "$TRANSPORT_PID" 2>/dev/null; then
        /bin/kill "$TRANSPORT_PID" 2>/dev/null || true
    fi
    [ -z "$INPUT_PID" ] || wait "$INPUT_PID" 2>/dev/null || true
    [ -z "$TRANSPORT_PID" ] || wait "$TRANSPORT_PID" 2>/dev/null || true
    /bin/rm -rf "$WORK_DIRECTORY"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/mkfifo "$INPUT_FIFO"
/usr/bin/nc -U "$SOCKET_PATH" <"$INPUT_FIFO" &
TRANSPORT_PID=$!
exec 3<&0
(
    if /bin/cat <&3 >"$INPUT_FIFO"; then
        : >"$INPUT_CLOSED"
        /bin/kill "$TRANSPORT_PID" 2>/dev/null || true
    fi
) &
INPUT_PID=$!
exec 3<&-

if wait "$TRANSPORT_PID"; then
    transport_status=0
else
    transport_status=$?
fi
TRANSPORT_PID=""

if [ -f "$INPUT_CLOSED" ]; then
    exit 0
fi
exit "$transport_status"
