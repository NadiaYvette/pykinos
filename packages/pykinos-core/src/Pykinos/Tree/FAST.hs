{-# LANGUAGE BangPatterns, DeriveFunctor, ScopedTypeVariables #-}

{- |
Module      : Pykinos.Tree.FAST
Description : Fast Architecture Sensitive Tree (FAST) cache-blocked search structure
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : EUPL-1.2
Maintainer  : Nadia Chambers <nadia.yvette.chambers@ik.me>
Stability   : experimental
Portability : non-portable (GHC extensions, primitive arrays)

Implements the Fast Architecture Sensitive Tree (FAST) layout derived from
Kim et al. (SIGMOD 2010), /"FAST: Fast Architecture Sensitive Tree Search on Modern CPUs and GPUs"/.

= Architectural Rationale

Traditional balanced binary trees (such as red-black trees or AVL trees) and
even cache-conscious B-trees incur pointer-chasing overhead across non-contiguous
heap objects:
1. Each branch navigation traverses a heap pointer to a separate cache line.
2. Branch predictors struggle with binary traversal patterns.
3. Hardware memory prefetchers cannot predict irregular memory strides.

FAST resolves these hardware bottlenecks by flattening an ordered collection
into a 1-based __Eytzinger__ (breadth-first array) layout:
* Root resides at index 1.
* For any node at index \(i\), its left child is at \(2i\) and right child is at \(2i + 1\).
* Children of consecutive nodes are contiguous in memory, allowing hardware streaming
  prefetchers to anticipate memory accesses across levels.
* Tree levels map cleanly into L1/L2 cache lines with zero pointer indirection.

FAST structures in Pykinos are immutable snapshots materialized by 'freezeFAST'
from a mutable or transient 'BPlusMap', providing high-throughput read-only
accelerators for symbol lookups and index sweeps.
-}
module Pykinos.Tree.FAST
  ( -- * FAST Accelerator Structure
    FASTMap(..)
    -- * Construction & Freezing
  , freezeFAST
    -- * Queries
  , lookupFAST
  , sizeFAST
  ) where

import Control.Monad.ST (runST)
import Data.Bits (unsafeShiftL)
import Data.Primitive.SmallArray
import Pykinos.Tree.BPlus (BPlusMap, toAscListBPlus)

-- | Fast Architecture Sensitive Tree (FAST) cache-line-blocked array.
--
-- Flattened 1-based Eytzinger array layout representing a perfectly balanced
-- complete search tree in contiguous unboxed 'SmallArray' slices.
data FASTMap k v = FASTMap
  { fmSize      :: {-# UNPACK #-} !Int
    -- ^ Number of stored key-value entries.
  , fmEytzKeys  :: {-# UNPACK #-} !(SmallArray k)
    -- ^ Keys stored in 1-based Eytzinger breadth-first ordering. Index 0 is unused padding.
  , fmEytzVals  :: {-# UNPACK #-} !(SmallArray v)
    -- ^ Values aligned with keys in 1-based Eytzinger ordering.
  } deriving (Eq, Show, Functor)

-- | Query the total number of entries in the 'FASTMap'.
--
-- Running time: \(O(1)\).
{-# INLINE sizeFAST #-}
sizeFAST :: FASTMap k v -> Int
sizeFAST = fmSize

-- | Freeze an ordered 'BPlusMap' into a contiguous cache-line-blocked 'FASTMap'.
--
-- Traverses the B+ tree in ascending key order via an in-order traversal and writes
-- elements directly into 1-based Eytzinger breadth-first slots in a single \(O(n)\) pass.
--
-- Running time: \(O(n)\) where \(n\) is the number of elements in the tree.
-- Memory footprint: \(2 \times (n + 1)\) slots in two contiguous 'SmallArray' buffers.
freezeFAST :: forall k v. BPlusMap k v -> FASTMap k v
freezeFAST !bpm =
  let !pairs = toAscListBPlus bpm
      !n     = length pairs
  in if n == 0
       then FASTMap 0 (smallArrayFromList []) (smallArrayFromList [])
       else
         let !sortedK = smallArrayFromList (map fst pairs)
             !sortedV = smallArrayFromList (map snd pairs)
             (!eytzK, !eytzV) = runST $ do
               let !k0 = indexSmallArray sortedK 0
                   !v0 = indexSmallArray sortedV 0
               mk <- newSmallArray (n + 1) k0
               mv <- newSmallArray (n + 1) v0
               -- Recursive in-order traversal mapping sorted index to Eytzinger breadth-first node index.
               let build !nodeIdx !srcIdx
                     | nodeIdx > n = pure srcIdx
                     | otherwise   = do
                         !srcIdx' <- build (2 * nodeIdx) srcIdx
                         writeSmallArray mk nodeIdx (indexSmallArray sortedK srcIdx')
                         writeSmallArray mv nodeIdx (indexSmallArray sortedV srcIdx')
                         build (2 * nodeIdx + 1) (srcIdx' + 1)
               _ <- build 1 0
               fk <- unsafeFreezeSmallArray mk
               fv <- unsafeFreezeSmallArray mv
               pure (fk, fv)
         in FASTMap n eytzK eytzV

-- | Branch-minimized binary search lookup over the contiguous Eytzinger array.
--
-- Navigates down the implicit binary tree using bitwise arithmetic:
-- * Left child:  @idx `unsafeShiftL` 1@ (i.e. \(2 \cdot \text{idx}\))
-- * Right child: @(idx `unsafeShiftL` 1) + 1@ (i.e. \(2 \cdot \text{idx} + 1\))
--
-- Running time: \(O(\log n)\) with zero pointer dereferences and optimal cacheline utilization.
lookupFAST :: Ord k => k -> FASTMap k v -> Maybe v
lookupFAST !q (FASTMap !n keys vals)
  | n == 0    = Nothing
  | otherwise = go 1
  where
    go !idx
      | idx > n   = Nothing
      | otherwise =
          let !k = indexSmallArray keys idx
          in case compare q k of
               EQ -> Just (indexSmallArray vals idx)
               LT -> go (idx `unsafeShiftL` 1)
               GT -> go ((idx `unsafeShiftL` 1) + 1)
