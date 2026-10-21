#!/bin/bash
# Regenerates docs/brand/ (icon, logo, banner). Usage: scripts/brand.sh [ac-panel.png] [lights-panel.png]
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
cat scripts/icon-art.swift scripts/brand.swift > "$TMP/brand.swift"
swift "$TMP/brand.swift" "${1:-docs/images/panel-dark.png}" "${2:-docs/images/lights-dark.png}"
