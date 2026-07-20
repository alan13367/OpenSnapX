#!/usr/bin/env bash
set -euo pipefail

# Build only — does not quit or launch OpenSnapX.
# For build + launch, use ./script/build_and_run.sh

APP_NAME="OpenSnapX"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
SIGNING_ARGS=()

cd "$ROOT_DIR"

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

echo "Built $APP_BUNDLE"
