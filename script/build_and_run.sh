#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OpenSnapX"
BUNDLE_ID="io.github.alan13367.OpenSnapX"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
SIGNING_ARGS=()

cd "$ROOT_DIR"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ ! -d "$ROOT_DIR/OpenSnapX.xcodeproj" || "$ROOT_DIR/project.yml" -nt "$ROOT_DIR/OpenSnapX.xcodeproj/project.pbxproj" ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required. Install it with: brew install xcodegen" >&2
    exit 1
  fi
  xcodegen generate
fi

if [[ "${OPEN_SNAPX_AD_HOC_SIGN:-0}" != "1" ]]; then
  SIGNING_IDENTITY_LINE="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print; exit }')"
  SIGNING_HASH="$(awk '{ print $2 }' <<<"$SIGNING_IDENTITY_LINE")"
  SIGNING_NAME="$(sed -E 's/^[^"]*"([^"]+)".*/\1/' <<<"$SIGNING_IDENTITY_LINE")"

  if [[ -n "$SIGNING_HASH" && -n "$SIGNING_NAME" ]]; then
    CERTIFICATE_SUBJECT="$(security find-certificate -c "$SIGNING_NAME" -p 2>/dev/null | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true)"
    DEVELOPMENT_TEAM="$(sed -E 's/.*OU=([^,]+).*/\1/' <<<"$CERTIFICATE_SUBJECT")"
    if [[ -n "$DEVELOPMENT_TEAM" && "$DEVELOPMENT_TEAM" != "$CERTIFICATE_SUBJECT" ]]; then
      SIGNING_ARGS=(
        "CODE_SIGN_IDENTITY=Apple Development"
        "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
      )
      echo "Using Apple Development signing for stable macOS privacy permissions."
    fi
  fi
fi

if [[ ${#SIGNING_ARGS[@]} -eq 0 ]]; then
  echo "Warning: using ad-hoc signing; Screen Recording permission may reset after rebuilds." >&2
fi

xcodebuild \
  -project OpenSnapX.xcodeproj \
  -scheme OpenSnapX \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  "${SIGNING_ARGS[@]}"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
