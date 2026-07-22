#!/bin/sh
set -eu

usage() {
    cat >&2 <<'EOF'
Usage: call.sh [--text|--raw] TOOL [JSON_ARGUMENTS]

Options:
  --text  Print only recognized text from opensnapx_capture_window_ocr.
  --raw   Print the complete JSON-RPC response for debugging.

Examples:
  call.sh opensnapx_status
  call.sh opensnapx_list_windows '{"query":"Xcode"}'
  call.sh --text opensnapx_capture_window_ocr '{"window_id":123}'
  call.sh --text opensnapx_capture_window_ocr '{"query":"Xcode","region":{"x":0,"y":0,"width":1,"height":0.5}}'
EOF
    exit 64
}

FORMAT=structured
case "${1:-}" in
    --text)
        FORMAT=text
        shift
        ;;
    --raw)
        FORMAT=raw
        shift
        ;;
esac

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
TOOL="$1"
if [ "$#" -eq 2 ]; then
    ARGUMENTS="$2"
else
    ARGUMENTS='{}'
fi

case "$TOOL" in
    opensnapx_status|opensnapx_list_windows|opensnapx_capture_window_ocr) ;;
    *) usage ;;
esac
[ "$FORMAT" != text ] || [ "$TOOL" = opensnapx_capture_window_ocr ] || usage
if ! ARGUMENTS=$(printf '%s' "$ARGUMENTS" | /usr/bin/plutil -convert json -o - -- - 2>/dev/null); then
    echo "JSON_ARGUMENTS must be valid JSON." >&2
    exit 64
fi
case "$ARGUMENTS" in
    \{*) ;;
    *)
        echo "JSON_ARGUMENTS must be a JSON object." >&2
        exit 64
        ;;
esac

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONNECTOR="$SCRIPT_DIRECTORY/connect.sh"
WORK_DIRECTORY=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/opensnapx-mcp-call.XXXXXX")
INPUT_FIFO="$WORK_DIRECTORY/input"
OUTPUT_FILE="$WORK_DIRECTORY/output"
ERROR_FILE="$WORK_DIRECTORY/error"
RESPONSE_FILE="$WORK_DIRECTORY/response"
TRANSPORT_PID=""
INPUT_OPEN=false

cleanup() {
    if [ "$INPUT_OPEN" = true ]; then
        exec 3>&-
        INPUT_OPEN=false
    fi
    if [ -n "$TRANSPORT_PID" ] && /bin/kill -0 "$TRANSPORT_PID" 2>/dev/null; then
        /bin/kill "$TRANSPORT_PID" 2>/dev/null || true
        wait "$TRANSPORT_PID" 2>/dev/null || true
    fi
    /bin/rm -rf "$WORK_DIRECTORY"
}
trap cleanup EXIT HUP INT TERM

/usr/bin/mkfifo "$INPUT_FIFO"
"$CONNECTOR" <"$INPUT_FIFO" >"$OUTPUT_FILE" 2>"$ERROR_FILE" &
TRANSPORT_PID=$!
exec 3>"$INPUT_FIFO"
INPUT_OPEN=true

printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"opensnapx-skill-helper","version":"1.0"}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&3
printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$TOOL" "$ARGUMENTS" >&3

attempts=0
response_ready=false
while [ "$attempts" -lt 1200 ]; do
    if [ -s "$OUTPUT_FILE" ] \
        && [ "$(/usr/bin/tail -c 1 "$OUTPUT_FILE" | /usr/bin/od -An -t uC | /usr/bin/tr -d ' ')" = "10" ] \
        && [ "$(/usr/bin/wc -l <"$OUTPUT_FILE" | /usr/bin/tr -d ' ')" -ge 2 ]; then
        response_ready=true
        break
    fi
    if ! /bin/kill -0 "$TRANSPORT_PID" 2>/dev/null; then
        break
    fi
    attempts=$((attempts + 1))
    /bin/sleep 0.05
done

exec 3>&-
INPUT_OPEN=false
if /bin/kill -0 "$TRANSPORT_PID" 2>/dev/null; then
    /bin/kill "$TRANSPORT_PID" 2>/dev/null || true
fi
wait "$TRANSPORT_PID" 2>/dev/null || true
TRANSPORT_PID=""

if [ "$response_ready" != true ]; then
    if [ -s "$ERROR_FILE" ]; then
        /bin/cat "$ERROR_FILE" >&2
    else
        echo "OpenSnapX did not return an MCP response before the timeout." >&2
    fi
    exit 1
fi

/usr/bin/tail -n 1 "$OUTPUT_FILE" >"$RESPONSE_FILE"
is_error=false
if [ "$(/usr/bin/plutil -extract result.isError raw -o - "$RESPONSE_FILE" 2>/dev/null || true)" = true ] \
    || /usr/bin/plutil -extract error json -o /dev/null "$RESPONSE_FILE" 2>/dev/null; then
    is_error=true
fi

if [ "$FORMAT" = raw ]; then
    /bin/cat "$RESPONSE_FILE"
elif [ "$is_error" = true ]; then
    /usr/bin/plutil -extract result.structuredContent json -o - "$RESPONSE_FILE" 2>/dev/null \
        || /bin/cat "$RESPONSE_FILE"
elif [ "$FORMAT" = text ]; then
    /usr/bin/plutil -extract result.structuredContent.text raw -o - "$RESPONSE_FILE"
else
    /usr/bin/plutil -extract result.structuredContent json -o - "$RESPONSE_FILE"
fi

[ "$is_error" != true ]
