#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

pkill -x BatteryManager 2>/dev/null && sleep 0.5 || true

swift build -c debug 2>&1 && .build/debug/BatteryManager
