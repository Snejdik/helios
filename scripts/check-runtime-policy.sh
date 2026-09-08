#!/bin/bash
# Static runtime-policy guard. Development scripts may invoke tools; runtime Swift may not.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build

if grep -RInE '\b(Process|NSTask)[[:space:]]*\(|\b(posix_spawn|popen)[[:space:]]*\(' Sources --include='*.swift' > .build/runtime-policy-violations.txt 2>/dev/null; then
  cat .build/runtime-policy-violations.txt
  echo "FAIL runtime source contains a forbidden subprocess/spawn API"
  exit 1
fi
rm -f .build/runtime-policy-violations.txt

# Swift 6.2/macOS 26 deprecates String(cString:). Keep runtime C-string
# decoding explicit and bounded so warnings-as-errors cannot regress later.
if grep -RInF 'String(cString:' Sources --include='*.swift' > .build/deprecated-cstring-violations.txt 2>/dev/null; then
  cat .build/deprecated-cstring-violations.txt
  echo "FAIL runtime source contains deprecated String(cString:)"
  exit 1
fi
rm -f .build/deprecated-cstring-violations.txt

# Bluetooth inventory is privacy-sensitive on modern macOS. Missing this key
# causes TCC to terminate a normally launched app before the status item can live.
if ! grep -q '<key>NSBluetoothAlwaysUsageDescription</key>' Resources/HeliosApp-Info.plist; then
  echo "FAIL HeliosApp Info.plist is missing NSBluetoothAlwaysUsageDescription"
  exit 1
fi

# Helios inventories audio devices but does not record audio. Keep normal telemetry
# away from CoreAudio input scope so Hardened Runtime does not require Audio Input
# entitlement / microphone permission merely to render the device inventory.
if grep -nE 'kAudioDevicePropertyScopeInput|kAudioHardwarePropertyDefaultInputDevice' Sources/HeliosApp/Telemetry/AudioProvider.swift > .build/audio-input-privacy-violations.txt 2>/dev/null; then
  cat .build/audio-input-privacy-violations.txt
  echo "FAIL AudioProvider probes microphone/input scope"
  exit 1
fi
rm -f .build/audio-input-privacy-violations.txt

if grep -qE 'com\.apple\.security\.device\.(audio-input|microphone)' Config/Helios.entitlements; then
  echo "FAIL Helios unexpectedly requests microphone/audio-input entitlement"
  exit 1
fi

echo "PASS runtime sources contain no forbidden subprocess/deprecated C-string path; Bluetooth privacy usage is declared and audio inventory avoids microphone scope"
