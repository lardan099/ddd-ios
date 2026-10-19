#!/bin/bash
# Скриншоты для README в iOS-симуляторе (macOS + Xcode). В CI — workflow «Screenshots».
#   bash tools/screenshots.sh <путь к LampaPlayer.app под симулятор> [папка для картинок]
# Приложение запускается с LP_SHOT=<сцена> (см. LampaPlayer/Demo.swift) и само открывает нужный экран.
set -euo pipefail

APP="$1"
OUT="${2:-docs/screenshots}"
RAW="$(mktemp -d)"
LOGS="${LOGS_DIR:-screenshot-logs}"
BUNDLE=com.lampaplayer.app
mkdir -p "$OUT" "$LOGS"

# Самый свежий iPhone … Pro (не Max) на самой свежей iOS.
DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.split(".iOS-")[1].split("-"))
    for d in devices:
        if d["name"].startswith("iPhone") and d["name"].endswith(" Pro"):
            key = (version, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"])
print(best[1])
print(best[2], best[0][0], file=sys.stderr)
')
echo "Simulator: $DEVICE"

xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl ui "$DEVICE" appearance dark
xcrun simctl status_bar "$DEVICE" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl install "$DEVICE" "$APP"

# Фильм и субтитры — локально в Documents/demo приложения (см. Demo.swift): без технической
# надписи тестового HLS и без зависимости от сервера Blender во время съёмки (он режет частые запросы).
DEMO="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)/Documents/demo"
mkdir -p "$DEMO"
TOS=https://download.blender.org/demo/movies/ToS
fetch() {
  curl -fsSL --retry 6 --retry-delay 20 --retry-all-errors -o "$2" "$1" || { echo "не скачалось: $1"; rm -f "$2"; }
}
fetch "$TOS/tears_of_steel_720p.mov" "$DEMO/tos.mov"
for lang in ru en de es fr-orig it; do fetch "$TOS/subtitles/TOS-$lang.srt" "$DEMO/TOS-$lang.srt"; done
ls -lh "$DEMO"

shot() {
  local scene="$1" wait="$2" landscape="${3:-}"
  echo "== $scene (ждём ${wait} с)"
  SIMCTL_CHILD_LP_SHOT="$scene" xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE"
  sleep "$wait"
  xcrun simctl io "$DEVICE" screenshot "$RAW/$scene.png"
  # simctl снимает экран в портретной раскладке, горизонтальный интерфейс выходит боком.
  if [[ -n "$landscape" ]]; then sips -r 270 "$RAW/$scene.png" > /dev/null; fi
  xcrun simctl spawn "$DEVICE" log show --last "$((wait + 5))s" --style compact \
    --predicate 'process == "LampaPlayer"' > "$LOGS/$scene.log" 2>&1 || true
  # Для README хватит ~1400 px по длинной стороне, JPEG в разы меньше PNG.
  sips -s format jpeg -s formatOptions 82 -Z 1400 "$RAW/$scene.png" --out "$OUT/$scene.jpg" > /dev/null
  sips -g pixelWidth -g pixelHeight "$OUT/$scene.jpg" | tail -2 | tr '\n' ' '
  echo
}

shot lampa 30
shot lampa-card 35
shot settings 20
shot settings-torr 25
shot player 30 landscape
shot subs 30 landscape
shot skip 30 landscape
shot next 25 landscape
shot tracks 30 landscape
shot playlist 30 landscape
shot tuning 30 landscape
shot tech 30 landscape
shot portrait 30

xcrun simctl terminate "$DEVICE" "$BUNDLE" || true
ls -lh "$OUT"
