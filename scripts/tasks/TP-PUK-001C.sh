#!/usr/bin/env bash
set -euo pipefail

echo "=== [TP-PUK-001C] Deploying Pykinos.Effect.Penelope ==="

mkdir -p pykinos-penelope/src/Pykinos/Effect pykinos-penelope/test

# 1. Update cabal.project
cat << 'EOF' > cabal.project
packages:
    pykinos-core
    pykinos-penelope

with-compiler: ghc-9.14.1
write-ghc-environment-files: always

package *
    ghc-options: -Wall -Wcompat -Wredundant-constraints
EOF

# 2. Mount seed
cp -f /home/nyc/src/plans/seeds/TP-PUK-001C-Penelope.hs pykinos-penelope/src/Pykinos/Effect/Penelope.hs

# 3. Write pykinos-penelope.cabal
cat << 'EOF' > pykinos-penelope/pykinos-penelope.cabal
cabal-version: 3.0
name: pykinos-penelope
version: 0.1.0.0
synopsis: Transient Epoch# In-Place Mutation and Lockless MVCC Handles
license: Apache-2.0
build-type: Simple
tested-with: GHC == 9.14.1

library
    exposed-modules:
        Pykinos.Effect.Penelope
    hs-source-dirs: src
    default-language: GHC2024
    ghc-options:
        -Wall
        -Wcompat
        -Widentities
        -Wno-unused-imports
    build-depends:
        base >= 4.19 && < 5,
        pykinos-core,
        primitive >= 0.9,
        containers >= 0.6

test-suite pykinos-penelope-test
    type: exitcode-stdio-1.0
    main-is: Spec.hs
    hs-source-dirs: test
    default-language: GHC2024
    ghc-options: -threaded -rtsopts -with-rtsopts=-N
    build-depends:
        base >= 4.19 && < 5,
        pykinos-core,
        pykinos-penelope,
        primitive >= 0.9
EOF

# 4. Write test/Spec.hs
cat << 'EOF' > pykinos-penelope/test/Spec.hs
{-# LANGUAGE BangPatterns #-}
module Main (main) where

import System.Exit (exitFailure)
import Pykinos.Tree.BPlus
import Pykinos.Tree.FAST
import Pykinos.Effect.Penelope

assertBool :: String -> Bool -> IO ()
assertBool name cond =
  if cond
    then putStrLn $ "  [PASS] " ++ name
    else do
      putStrLn $ "  [FAIL] " ++ name
      exitFailure

main :: IO ()
main = do
  putStrLn "=== [pykinos-penelope-test] Running Transient Epoch & MVCC Pushout Suite ==="

  -- 1. Transient Epoch batch mutation
  let baseTree = insertBPlus (1 :: Int) ("init1" :: String) emptyBPlus
      (ep1, tree1) = withTransientEpoch 0 baseTree $ \ep ins acc ->
        ins 2 "val2" (ins 3 "val3" acc)

  assertBool "epoch advanced to 1" (ep1 == 1)
  assertBool "tree1 contains 1" (lookupBPlus 1 tree1 == Just "init1")
  assertBool "tree1 contains 2" (lookupBPlus 2 tree1 == Just "val2")
  assertBool "tree1 contains 3" (lookupBPlus 3 tree1 == Just "val3")

  -- 2. Lockless MVCC Snapshot with FAST accelerator
  let snap1 = mvccSnapshot ep1 True tree1
  assertBool "snap1 epoch is 1" (msEpoch snap1 == 1)
  assertBool "snap1 has FAST accelerator" (case msFastAcc snap1 of Just _ -> True; Nothing -> False)
  let Just fAcc = msFastAcc snap1
  assertBool "FAST accelerator lookup 2" (lookupFAST 2 fAcc == Just "val2")

  -- 3. Commutative Disjoint Pushout Merge
  -- Worker A inserts (4, "val4"), Worker B inserts (5, "val5")
  let treeA = insertBPlus 4 "val4" tree1
      treeB = insertBPlus 5 "val5" tree1
      resMerge = commitEpochPushout snap1 treeA treeB

  assertBool "disjoint merge succeeds" (case resMerge of Right _ -> True; Left _ -> False)
  let Right mergedSnap = resMerge
  assertBool "mergedSnap epoch is 2" (msEpoch mergedSnap == 2)
  assertBool "merged contains 1" (lookupBPlus 1 (msTree mergedSnap) == Just "init1")
  assertBool "merged contains 4" (lookupBPlus 4 (msTree mergedSnap) == Just "val4")
  assertBool "merged contains 5" (lookupBPlus 5 (msTree mergedSnap) == Just "val5")

  -- 4. Overlapping Equal Value Pushout Merge
  let treeA2 = insertBPlus 10 "same" tree1
      treeB2 = insertBPlus 10 "same" tree1
      resMerge2 = commitEpochPushout snap1 treeA2 treeB2
  assertBool "equal overlap merge succeeds" (case resMerge2 of Right _ -> True; Left _ -> False)

  -- 5. Conflicting Divergent Pushout Merge (H^1 Obstruction)
  let treeConfA = insertBPlus 10 "branchA" tree1
      treeConfB = insertBPlus 10 "branchB" tree1
      resConf = commitEpochPushout snap1 treeConfA treeConfB

  assertBool "conflicting pushout returns Left" (case resConf of Left _ -> True; Right _ -> False)
  let Left [conflict] = resConf
  assertBool "conflict key is 10" (pcKey conflict == 10)
  assertBool "conflict left is branchA" (pcLeftVal conflict == "branchA")
  assertBool "conflict right is branchB" (pcRightVal conflict == "branchB")

  putStrLn "=== [pykinos-penelope-test] ALL 14 PROPERTIES AND UNIT CHECKS PASSED ==="
EOF

echo "=== [TP-PUK-001C] Building and testing pykinos-penelope ==="
cabal v2-build pykinos-penelope -j20 --semaphore
cabal v2-test pykinos-penelope

echo "=== [TP-PUK-001C] Execution script complete ==="
