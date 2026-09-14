#!/bin/bash
# Deterministic, offline app-level release checks. No helper or hardware access.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path .build/Checks/ModuleCache \
  Sources/HeliosApp/HeliosUpdateChecker.swift Tests/UpdateChecks.swift \
  -o .build/Checks/UpdateChecks
.build/Checks/UpdateChecks
