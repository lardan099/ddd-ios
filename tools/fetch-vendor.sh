#!/bin/bash
# Скачивает TorrServerKit.xcframework (встроенный TorrServer) в Vendor/.
# Нужен и в CI, и для локальной сборки на Mac перед `xcodegen generate`.
set -euo pipefail

TORRSERVER_VERSION="${TORRSERVER_VERSION:-MatriX.147}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
STAMP="$VENDOR/.torrserver-version"

if [[ -d "$VENDOR/TorrServerKit.xcframework" && -f "$STAMP" && "$(cat "$STAMP")" == "$TORRSERVER_VERSION" ]]; then
  echo "TorrServerKit $TORRSERVER_VERSION already present"
  exit 0
fi

mkdir -p "$VENDOR"
rm -rf "$VENDOR/TorrServerKit.xcframework"
TMP="$(mktemp -d)"
curl -fL --retry 3 -o "$TMP/ts.zip" \
  "https://github.com/YouROK/TorrServer/releases/download/${TORRSERVER_VERSION}/TorrServer-ios-TorrServerKit.xcframework.zip"
unzip -q "$TMP/ts.zip" -d "$VENDOR"
rm -rf "$TMP"
echo "$TORRSERVER_VERSION" > "$STAMP"
echo "TorrServerKit $TORRSERVER_VERSION -> $VENDOR/TorrServerKit.xcframework"
