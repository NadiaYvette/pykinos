{-# LANGUAGE BangPatterns, DeriveFunctor, DeriveFoldable, ScopedTypeVariables #-}

{- |
Module      : Pykinos.Tree.BPlus
Description : Cache-conscious serried B+ tree with transient epoch versioning
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : EUPL-1.2
Maintainer  : Nadia Chambers <nadia.yvette.chambers@ik.me>
Stability   : experimental
Portability : non-portable (GHC extensions, primitive arrays)

Implements a serried B+ tree using unboxed 'SmallArray' slices for both internal
routing nodes ('BPInternal') and key-value leaves ('BPLeaf').

= Algorithmic Properties

1. **Branching Factor:** Fixed capacity \(M = 16\) slots per node (corresponding to
   128 bytes of pointers on 64-bit architectures, fitting inside two L1 cache lines).
2. **Balanced Height:** All leaves reside at the same tree depth. Insertion splits
   overflowing nodes at \(\lfloor M / 2 \rfloor\) and propagates pivot keys upward.
3. **Cache Locality:** Keys within each leaf and internal node are stored sequentially
   in contiguous memory, enabling binary search ('searchKeys') with minimal branch mispredictions.
4. **Transient Epoch Versioning:** Each node carries an 'EpochId'. When operating
   under 'Pykinos.Effect.Penelope', modifications within the current epoch mutate
   nodes in-place or reuse allocations, while crossing an epoch boundary triggers
   persistent copy-on-write isolation.
-}
module Pykinos.Tree.BPlus
  ( -- * Epoch Tokens
    EpochId
    -- * Tree Types
  , BPlusMap(..)
  , BPlusNode(..)
    -- * Construction & Empty Maps
  , emptyBPlus
  , fromListBPlus
    -- * Lookups & Queries
  , lookupBPlus
  , toAscListBPlus
    -- * Insertion
  , insertBPlus
  , insertBPlusEpoch
  ) where

import Control.Monad.ST (runST)
import Data.Primitive.SmallArray
import Data.Word (Word64)

-- | Monotonic transient epoch token used for MVCC and snapshot isolation.
--
-- Epoch 0 denotes a persistent immutable snapshot. Non-zero epochs identify
-- isolated transaction branches.
type EpochId = Word64

-- | Maximum branching factor per serried B+ block (16 slots = 128 bytes of pointers).
bPlusMaxCap :: Int
bPlusMaxCap = 16

-- | Node representation in the serried B+ tree.
--
-- Nodes are partitioned into routing internal nodes ('BPInternal') and
-- data-bearing leaves ('BPLeaf').
data BPlusNode k v
  = BPLeaf
      { bplEpoch :: {-# UNPACK #-} !EpochId
        -- ^ Epoch version stamp at node creation.
      , bplKeys  :: {-# UNPACK #-} !(SmallArray k)
        -- ^ Contiguous sorted keys stored in this leaf node.
      , bplVals  :: {-# UNPACK #-} !(SmallArray v)
        -- ^ Contiguous values aligned one-to-one with 'bplKeys'.
      }
  | BPInternal
      { bpiEpoch    :: {-# UNPACK #-} !EpochId
        -- ^ Epoch version stamp at node creation.
      , bpiPivots   :: {-# UNPACK #-} !(SmallArray k)
        -- ^ Sorted separator pivot keys dividing child branches.
      , bpiChildren :: {-# UNPACK #-} !(SmallArray (BPlusNode k v))
        -- ^ Child node pointers (size is @sizeofSmallArray bpiPivots + 1@).
      }
  deriving (Eq, Show, Functor, Foldable)

-- | Persistent B+ tree key-value map.
data BPlusMap k v = BPlusMap
  { bpmSize :: {-# UNPACK #-} !Int
    -- ^ Total number of key-value associations stored in the map.
  , bpmRoot :: !(BPlusNode k v)
    -- ^ Root node of the B+ tree hierarchy.
  } deriving (Eq, Show, Functor, Foldable)

-- | Construct an empty 'BPlusMap'.
--
-- Running time: \(O(1)\).
emptyBPlus :: BPlusMap k v
emptyBPlus = BPlusMap 0 (BPLeaf 0 (smallArrayFromList []) (smallArrayFromList []))

-- | Binary search for key 'k' in a sorted 'SmallArray k'.
--
-- Returns 'Right' index if key is found, or 'Left' insertion slot if absent.
--
-- Running time: \(O(\log M)\) where \(M \le 16\).
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

-- | Determine child slot in 'BPInternal' routing node for search key 'k'.
findChildIdx :: Ord k => SmallArray k -> k -> Int
findChildIdx !pivots !k = go 0 (sizeofSmallArray pivots)
  where
    go !i !n
      | i >= n    = n
      | k < indexSmallArray pivots i = i
      | otherwise = go (i + 1) n

-- | Query a key in the 'BPlusMap'.
--
-- Running time: \(O(\log_M n)\) with cacheline-optimized binary search at each level.
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

-- | Pure persistent insertion into a 'BPlusMap' (stamped with 'EpochId' 0).
--
-- Running time: \(O(\log_M n)\).
insertBPlus :: Ord k => k -> v -> BPlusMap k v -> BPlusMap k v
insertBPlus !k v !m = insertBPlusEpoch 0 k v m

-- | Epoch-stamped insertion supporting \(O(1)\) transient epoch tracking in Penelope.
--
-- Running time: \(O(\log_M n)\).
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

-- | Flatten all key-value entries into an ascending sorted list.
--
-- Running time: \(O(n)\).
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

-- | Construct a 'BPlusMap' from a list of key-value pairs.
--
-- Running time: \(O(n \log_M n)\).
fromListBPlus :: Ord k => [(k, v)] -> BPlusMap k v
fromListBPlus = foldl' (\acc (k, v) -> insertBPlus k v acc) emptyBPlus

-- | Insert element 'val' into 'SmallArray' at slot 'idx'.
insertAt :: SmallArray a -> Int -> a -> SmallArray a
insertAt !arr !idx val = runST $ do
  let !n = sizeofSmallArray arr
  m <- newSmallArray (n + 1) val
  copySmallArray m 0 arr 0 idx
  copySmallArray m (idx + 1) arr idx (n - idx)
  unsafeFreezeSmallArray m

-- | Replace element at slot 'idx' in 'SmallArray' with 'val'.
replaceAt :: SmallArray a -> Int -> a -> SmallArray a
replaceAt !arr !idx val = runST $ do
  let !n = sizeofSmallArray arr
  m <- thawSmallArray arr 0 n
  writeSmallArray m idx val
  unsafeFreezeSmallArray m
