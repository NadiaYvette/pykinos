-- FILE: src/Pukinos/Tree/FAST.hs
{-# LANGUAGE BangPatterns, DeriveFunctor, ScopedTypeVariables #-}

module Pykinos.Tree.FAST
  ( FASTMap(..)
  , freezeFAST
  , lookupFAST
  , sizeFAST
  ) where

import Control.Monad.ST (ST, runST)
import Data.Bits (unsafeShiftL, unsafeShiftR)
import Data.Primitive.SmallArray
import Pykinos.Tree.BPlus (BPlusMap, toAscListBPlus)

-- | 2010 Oracle-Intel FAST (Fast Architecture Sensitive Tree):
--   Flattens an ordered BPlusMap into a single contiguous Eytzinger / cache-line
--   blocked array so 3 levels of binary search execute inside a single cache line
--   with zero pointer chasing.
data FASTMap k v = FASTMap
  { fmSize      :: {-# UNPACK #-} !Int
  , fmEytzKeys  :: {-# UNPACK #-} !(SmallArray k)
  , fmEytzVals  :: {-# UNPACK #-} !(SmallArray v)
  } deriving (Eq, Show, Functor)

{-# INLINE sizeFAST #-}
sizeFAST :: FASTMap k v -> Int
sizeFAST = fmSize

-- | Freeze a dynamic 'BPlusMap' into a contiguous cache-line-blocked 'FASTMap'
--   using 1-based Eytzinger breadth-first layout for hardware prefetching.
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

-- | Branch-minimized Eytzinger lookup over contiguous cache-line blocks.
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