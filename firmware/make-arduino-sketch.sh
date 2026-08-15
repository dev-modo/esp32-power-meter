#!/bin/bash
# Generate an Arduino IDE sketch folder from src/main.cpp.
#
# The Arduino IDE requires a folder X containing X.ino, which does not match the
# src/main.cpp layout PlatformIO uses. Rather than keeping a second copy of the
# firmware in the repo (where the two would silently drift apart), generate it
# on demand. src/main.cpp stays the single source of truth.
#
#   ./make-arduino-sketch.sh              -> ~/Desktop/PowerMeter/PowerMeter.ino
#   ./make-arduino-sketch.sh /some/path   -> /some/path/PowerMeter/PowerMeter.ino

set -e
cd "$(dirname "$0")"
DEST="${1:-$HOME/Desktop}"
OUT="$DEST/PowerMeter"

mkdir -p "$OUT"
cp src/main.cpp "$OUT/PowerMeter.ino"

echo "Sketch written to $OUT/PowerMeter.ino"
echo
echo "Arduino IDE settings — the partition scheme is not optional:"
echo "  Board            : ESP32 Dev Module"
echo "  Partition Scheme : Minimal SPIFFS (1.9MB APP with OTA)"
echo "  Upload Speed     : 115200   (921600 is unreliable on CH340/CP2102 clones)"
echo
echo "Libraries (Sketch > Include Library > Manage Libraries):"
echo "  WiFiManager   by tzapu"
echo "  PZEM004Tv30   by Jakub Mandula      <- spelled exactly like this"
echo "  ArduinoJson   by Benoit Blanchon"
