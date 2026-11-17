#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-PUK-001A-verify] Running verification gate ==="
cabal v2-build pykinos-core -j20 --semaphore
cabal v2-test pykinos-core
echo "=== [TP-PUK-001A-verify] Gate PASS ==="
