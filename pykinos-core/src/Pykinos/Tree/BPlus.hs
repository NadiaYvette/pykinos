-- VERBATIM_CODE_SEED: TP-PUK-001B
-- TARGET_REPO: ~/src/pukinos
-- TARGET_PACKAGE: pukinos-core
-- TARGET_FILES:
--   src/Pukinos/Tree/BPlus.hs
--   src/Pukinos/Tree/FAST.hs

{-# LANGUAGE BangPatterns, DeriveFunctor, DeriveFoldable, ScopedTypeVariables #-}

module Pykinos.Tree.BPlus
  ( EpochId
  , BPlusMap(..)
  , BPlusNode(..)
  , emptyBPlus
  , lookupBPlus
  , insertBPlus
  , insertBPlusEpoch
  , toAscListBPlus
  , fromListBPlus
  ) where

import Control.Monad.ST (runST)
import Data.Primitive.SmallArray
import Data.Word (Word64)

-- | Monotonic transient epoch token used by 'Pykinos.Effect.Penelope' ('TP-PUK-001C').
type EpochId = Word64

-- | Maximum branching factor per serried B+ block (16 slots = 128 bytes of pointers).
bPlusMaxCap :: Int
bPlusMaxCap = 16

data BPlusNode k v
  = BPLeaf
      { bplEpoch :: {-# UNPACK #-} !EpochId
      , bplKeys  :: {-# UNPACK #-} !(SmallArray k)
      , bplVals  :: {-# UNPACK #-} !(SmallArray v)
      }
  | BPInternal
      { bpiEpoch    :: {-# UNPACK #-} !EpochId
      , bpiPivots   :: {-# UNPACK #-} !(SmallArray k)
      , bpiChildren :: {-# UNPACK #-} !(SmallArray (BPlusNode k v))
      }
  deriving (Eq, Show, Functor, Foldable)

data BPlusMap k v = BPlusMap
  { bpmSize :: {-# UNPACK #-} !Int
  , bpmRoot :: !(BPlusNode k v)
  } deriving (Eq, Show, Functor, Foldable)

emptyBPlus :: BPlusMap k v
emptyBPlus = BPlusMap 0 (BPLeaf 0 (smallArrayFromList []) (smallArrayFromList []))

-- | Binary search in a sorted 'SmallArray k'.
searchKeys :: Ord k => SmallArray k -> k -> Either Int Int
searchKeys !arr !k = go 0 (sizeofSmallArray arr - 1)
  where
    go !lo !hi
      | lo > hi   = Left lo
      | otherwise =
          let !mid = (lo + hi) `div` 2
              !kv  = indexSmallArray arr mid
          in case compare k kv of
               EQ -> Right mid
               LT -> go lo (mid - 1)
               GT -> go (mid + 1) hi

-- | Find child slot in 'BPInternal' for key 'k'.
findChildIdx :: Ord k => SmallArray k -> k -> Int
findChildIdx !pivots !k = go 0 (sizeofSmallArray pivots)
  where
    go !i !n
      | i >= n    = n
      | k < indexSmallArray pivots i = i
      | otherwise = go (i + 1) n

lookupBPlus :: Ord k => k -> BPlusMap k v -> Maybe v
lookupBPlus !k (BPlusMap _ root) = go root
  where
    go (BPLeaf _ keys vals) =
      case searchKeys keys k of
        Right !idx -> Just (indexSmallArray vals idx)
        Left _     -> Nothing
    go (BPInternal _ pivots children) =
      let !cIdx = findChildIdx pivots k
      in go (indexSmallArray children cIdx)

-- | Pure persistent insertion (uses EpochId = 0).
insertBPlus :: Ord k => k -> v -> BPlusMap k v -> BPlusMap k v
insertBPlus !k v !m = insertBPlusEpoch 0 k v m

-- | Epoch-stamped insertion supporting O(1) transient epoch tracking in 'TP-PUK-001C'.
insertBPlusEpoch :: Ord k => EpochId -> k -> v -> BPlusMap k v -> BPlusMap k v
insertBPlusEpoch !ep !k v (BPlusMap !sz root) =
  let (!added, !res) = insNode root
  in case res of
       Left !node' ->
         BPlusMap (if added then sz + 1 else sz) node'
       Right (!leftN, !pivotK, !rightN) ->
         let !newRoot = BPInternal ep (smallArrayFromList [pivotK]) (smallArrayFromList [leftN, rightN])
         in BPlusMap (if added then sz + 1 else sz) newRoot
  where
    insNode (BPLeaf _ keys vals) =
      case searchKeys keys k of
        Right !idx ->
          (False, Left (BPLeaf ep keys (replaceAt vals idx v)))
        Left !insIdx ->
          let !keys' = insertAt keys insIdx k
              !vals' = insertAt vals insIdx v
              !len'  = sizeofSmallArray keys'
          in if len' <= bPlusMaxCap
               then (True, Left (BPLeaf ep keys' vals'))
               else
                 let !mid   = len' `div` 2
                     !kL    = cloneSmallArray keys' 0 mid
                     !vL    = cloneSmallArray vals' 0 mid
                     !kR    = cloneSmallArray keys' mid (len' - mid)
                     !vR    = cloneSmallArray vals' mid (len' - mid)
                     !piv   = indexSmallArray kR 0
                 in (True, Right (BPLeaf ep kL vL, piv, BPLeaf ep kR vR))

    insNode (BPInternal _ pivots children) =
      let !cIdx = findChildIdx pivots k
          (!added, !childRes) = insNode (indexSmallArray children cIdx)
      in case childRes of
           Left !c' ->
             (added, Left (BPInternal ep pivots (replaceAt children cIdx c')))
           Right (!cL, !piv, !cR) ->
             let !pivots'   = insertAt pivots cIdx piv
                 !children' = insertAt (replaceAt children cIdx cL) (cIdx + 1) cR
                 !cLen      = sizeofSmallArray children'
             in if cLen <= bPlusMaxCap
                  then (added, Left (BPInternal ep pivots' children'))
                  else
                    let !mid    = cLen `div` 2
                        !upPiv  = indexSmallArray pivots' (mid - 1)
                        !pL     = cloneSmallArray pivots' 0 (mid - 1)
                        !pR     = cloneSmallArray pivots' mid (sizeofSmallArray pivots' - mid)
                        !chL    = cloneSmallArray children' 0 mid
                        !chR    = cloneSmallArray children' mid (cLen - mid)
                    in (added, Right (BPInternal ep pL chL, upPiv, BPInternal ep pR chR))

toAscListBPlus :: BPlusMap k v -> [(k, v)]
toAscListBPlus (BPlusMap _ root) = go root []
  where
    go (BPLeaf _ keys vals) acc =
      let !n = sizeofSmallArray keys
          loop !i !a
            | i < 0     = a
            | otherwise = loop (i - 1) ((indexSmallArray keys i, indexSmallArray vals i) : a)
      in loop (n - 1) acc
    go (BPInternal _ _ children) acc =
      let !n = sizeofSmallArray children
          loop !i !a
            | i < 0     = a
            | otherwise = loop (i - 1) (go (indexSmallArray children i) a)
      in loop (n - 1) acc

fromListBPlus :: Ord k => [(k, v)] -> BPlusMap k v
fromListBPlus = foldl' (\acc (k, v) -> insertBPlus k v acc) emptyBPlus

insertAt :: SmallArray a -> Int -> a -> SmallArray a
insertAt !arr !idx val = runST $ do
  let !n = sizeofSmallArray arr
  m <- newSmallArray (n + 1) val
  copySmallArray m 0 arr 0 idx
  copySmallArray m (idx + 1) arr idx (n - idx)
  unsafeFreezeSmallArray m

replaceAt :: SmallArray a -> Int -> a -> SmallArray a
replaceAt !arr !idx val = runST $ do
  let !n = sizeofSmallArray arr
  m <- thawSmallArray arr 0 n
  writeSmallArray m idx val
  unsafeFreezeSmallArray m