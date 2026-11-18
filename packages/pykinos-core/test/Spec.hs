{-# LANGUAGE BangPatterns #-}
module Main (main) where

import System.Exit (exitFailure)
import Pykinos.Bitset.Roaring
import Pykinos.IntMap.ART
import Pykinos.Mutable.SwissTable
import Pykinos.Schema.HiddenClass
import qualified Data.Text as T
import Control.Monad.ST (runST)
import Pykinos.Tree.BPlus
import Pykinos.Tree.FAST

assertBool :: String -> Bool -> IO ()
assertBool name cond =
  if cond
    then putStrLn $ "  [PASS] " ++ name
    else do
      putStrLn $ "  [FAIL] " ++ name
      exitFailure

main :: IO ()
main = do
  putStrLn "=== [pykinos-core-test] Running Roaring & ART Test Suite ==="

  -- 1. Roaring Basic Operations
  let s0 = emptyRoaring
  assertBool "s0 is null" (nullRoaring s0)

  let s1 = singletonRoaring 42
  assertBool "s1 not null" (not (nullRoaring s1))
  assertBool "s1 contains 42" (memberRoaring 42 s1)
  assertBool "s1 does not contain 43" (not (memberRoaring 43 s1))

  -- 2. Roaring Dense Array / Bitmap Promotion (> 4096 entries in a single 16-bit block)
  let denseList = [0 .. 4500]
      sDense = fromListRoaring denseList
  assertBool "sDense contains 0" (memberRoaring 0 sDense)
  assertBool "sDense contains 4500" (memberRoaring 4500 sDense)
  assertBool "sDense does not contain 4501" (not (memberRoaring 4501 sDense))

  -- 3. Roaring Union, Intersect, Difference
  let setA = fromListRoaring [1, 2, 3, 100, 70000]
      setB = fromListRoaring [3, 4, 5, 100, 70001]
      uSet = unionRoaring setA setB
      iSet = intersectRoaring setA setB
      dSet = differenceRoaring setA setB

  assertBool "union contains 1" (memberRoaring 1 uSet)
  assertBool "union contains 5" (memberRoaring 5 uSet)
  assertBool "union contains 70000 and 70001" (memberRoaring 70000 uSet && memberRoaring 70001 uSet)
  assertBool "intersect contains 3 and 100" (memberRoaring 3 iSet && memberRoaring 100 iSet)
  assertBool "intersect does not contain 1" (not (memberRoaring 1 iSet))
  assertBool "diff contains 1, 2, 70000" (memberRoaring 1 dSet && memberRoaring 2 dSet && memberRoaring 70000 dSet)
  assertBool "diff does not contain 3 or 100" (not (memberRoaring 3 dSet) && not (memberRoaring 100 dSet))

  -- 4. ART IntMap Operations across Node sizes
  let m0 = emptyART :: ARTIntMap String
      m4 = foldr (\k acc -> artInsert k ("val-" ++ show k) acc) m0 [1..4]
  assertBool "m4 lookup 1" (artLookup 1 m4 == Just "val-1")
  assertBool "m4 lookup 4" (artLookup 4 m4 == Just "val-4")
  assertBool "m4 lookup 5 is Nothing" (artLookup 5 m4 == Nothing)

  let m16 = foldr (\k acc -> artInsert k ("val-" ++ show k) acc) m4 [5..16]
  assertBool "m16 lookup 16" (artLookup 16 m16 == Just "val-16")
  assertBool "m16 lookup 10" (artLookup 10 m16 == Just "val-10")

  let m48 = foldr (\k acc -> artInsert k ("val-" ++ show k) acc) m16 [17..48]
  assertBool "m48 lookup 48" (artLookup 48 m48 == Just "val-48")

  let m256 = foldr (\k acc -> artInsert k ("val-" ++ show k) acc) m48 [49..100]
  assertBool "m256 lookup 100" (artLookup 100 m256 == Just "val-100")
  assertBool "m256 member 75" (artMember 75 m256)
  assertBool "m256 member 101 False" (not (artMember 101 m256))

  let mDel = artDelete 50 m256
  assertBool "mDel lookup 50 is Nothing" (artLookup 50 mDel == Nothing)
  assertBool "mDel lookup 49 still Just" (artLookup 49 mDel == Just "val-49")

  let kSet = artKeysSet mDel
  assertBool "kSet contains 49" (memberRoaring 49 kSet)
  assertBool "kSet does not contain 50" (not (memberRoaring 50 kSet))

  -- 5. BPlusMap Tests (splits across multi-level blocks)
  let bp0 = emptyBPlus :: BPlusMap Int String
      bp100 = foldr (\k acc -> insertBPlus k ("v" ++ show k) acc) bp0 [1..100]
  assertBool "bp100 size is 100" (bpmSize bp100 == 100)
  assertBool "bp100 lookup 1" (lookupBPlus 1 bp100 == Just "v1")
  assertBool "bp100 lookup 50" (lookupBPlus 50 bp100 == Just "v50")
  assertBool "bp100 lookup 100" (lookupBPlus 100 bp100 == Just "v100")
  assertBool "bp100 lookup 101 is Nothing" (lookupBPlus 101 bp100 == Nothing)

  let ascList = toAscListBPlus bp100
  assertBool "ascList has 100 items" (length ascList == 100)
  assertBool "ascList is sorted" (map fst ascList == [1..100])

  -- 6. FASTMap Tests (Eytzinger Cache-line acceleration)
  let fast100 = freezeFAST bp100
  assertBool "fast100 size is 100" (sizeFAST fast100 == 100)
  assertBool "fast100 lookup 1" (lookupFAST 1 fast100 == Just "v1")
  assertBool "fast100 lookup 50" (lookupFAST 50 fast100 == Just "v50")
  assertBool "fast100 lookup 100" (lookupFAST 100 fast100 == Just "v100")
  assertBool "fast100 lookup 101 is Nothing" (lookupFAST 101 fast100 == Nothing)

  
  -- 7. SwissTable128 Tests (SWAR 128-bit hash-consing)
  let (id0, id1, id0_again) = runST $ do
        tbl <- newSwissTable128 32
        let (kLo1, kHi1) = packNfNode128 1 0 10 20 30
            (kLo2, kHi2) = packNfNode128 2 0 40 50 60
        i0 <- lookupOrInsert128 tbl kLo1 kHi1
        i1 <- lookupOrInsert128 tbl kLo2 kHi2
        i0' <- lookupOrInsert128 tbl kLo1 kHi1
        pure (i0, i1, i0')
  assertBool "id0 is 0" (id0 == 0)
  assertBool "id1 is 1" (id1 == 1)
  assertBool "id0_again matches id0" (id0_again == 0)

  
  -- 8. HiddenClass & Lexicon Tests
  let lx = buildLexicon [T.pack "beta", T.pack "alpha", T.pack "gamma"]
  assertBool "alpha fid is 0" (lookupFieldId lx (T.pack "alpha") == Just (FieldId 0))
  assertBool "beta fid is 1" (lookupFieldId lx (T.pack "beta") == Just (FieldId 1))
  assertBool "gamma fid is 2" (lookupFieldId lx (T.pack "gamma") == Just (FieldId 2))

  putStrLn "=== [pykinos-core-test] ALL 33 PROPERTIES AND UNIT CHECKS PASSED ==="
