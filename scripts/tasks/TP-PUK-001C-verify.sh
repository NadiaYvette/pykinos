#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-PUK-001C-verify] Running verification gate ==="
cabal v2-build pukinos-penelope -j20 --semaphore
cabal v2-test pukinos-penelope
echo "=== [TP-PUK-001C-verify] Gate PASS ==="
