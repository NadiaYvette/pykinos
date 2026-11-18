#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-PYKINOS-ARENA-001B Verification Gate] ==="
bin/pykinos-verify
cabal v2-test pykinos-core
echo "=== [TP-PYKINOS-ARENA-001B Verification Gate PASSED] ==="
