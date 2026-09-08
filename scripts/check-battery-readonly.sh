#!/bin/bash
# Battery policy boundary: Helios observes battery/charger state but never controls charging.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build

# The privileged helper is deliberately fan-only. Battery/charger policy must not
# migrate into root code as the product grows.
if grep -RInE '\b(Battery|battery|Charger|charger|charging|discharg(e|ing))\b' Sources/HeliosDaemon --include='*.swift' > .build/battery-daemon-violations.txt 2>/dev/null; then
  cat .build/battery-daemon-violations.txt
  echo "FAIL privileged daemon contains battery/charger policy code"
  exit 1
fi
rm -f .build/battery-daemon-violations.txt

# Battery control must not become representable over the authenticated XPC control
# surface either. Read-only battery telemetry never needs the root peer.
if grep -nEi '\b(battery|charger|charging|discharge|charge.?limit)\b' \
    Sources/Shared/HeliosXPCProtocol.swift Sources/HeliosApp/DaemonClient.swift > .build/battery-xpc-violations.txt 2>/dev/null; then
  cat .build/battery-xpc-violations.txt
  echo "FAIL XPC/daemon client exposes a battery-control surface"
  exit 1
fi
rm -f .build/battery-xpc-violations.txt

# The unprivileged battery provider may only read IOPowerSources/IORegistry data.
if grep -nE 'IORegistryEntrySet|IOConnectCall|SMCIOKitTransport|SMCClient|kSMCWrite|write\(' Sources/HeliosApp/Telemetry/BatteryProvider.swift > .build/battery-write-violations.txt 2>/dev/null; then
  cat .build/battery-write-violations.txt
  echo "FAIL BatteryProvider contains a write/control path"
  exit 1
fi
rm -f .build/battery-write-violations.txt

echo "PASS battery subsystem is telemetry-only and privileged helper remains fan-only"
