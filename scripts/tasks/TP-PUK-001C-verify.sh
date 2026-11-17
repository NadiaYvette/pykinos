#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-PUK-001C-verify] Running verification gate ==="
cabal v2-build pykinos-penelope -j20 --semaphore
cabal v2-test pykinos-penelope
echo "=== [TP-PUK-001C-verify] Gate PASS ==="
