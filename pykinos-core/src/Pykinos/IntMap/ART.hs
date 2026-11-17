-- FILE: src/Pukinos/IntMap/ART.hs
{-# LANGUAGE BangPatterns, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}

module Pykinos.IntMap.ART
  ( ARTIntMap(..)
  , emptyART
  , singletonART
  , artLookup
  , artMember
  , artInsert
  , artInsertWith
  , artDelete
  , artToList
  , artFromList
  , artKeysSet
  ) where

import Control.Monad.ST (runST)
import Data.Bits ((.&.), unsafeShiftR)
import Data.Primitive.PrimArray
import Data.Primitive.SmallArray
import Data.Word (Word8)
import Pykinos.Bitset.Roaring (RoaringIntSet, fromListRoaring)

-- | Adaptive Radix Tree (ART) IntMap with 4-tier span fanout:
--   * 'ARTLeaf'   : Path-compressed single key-value leaf
--   * 'ARTNode4'  : 1..4 children (unboxed Word8 key bytes + SmallArray children)
--   * 'ARTNode16' : 5..16 children (sorted Word8 key bytes + SmallArray children)
--   * 'ARTNode48' : 17..48 children (256-byte direct index table + up to 48 children)
--   * 'ARTNode256': 49..256 children (direct 256-slot SmallArray)
data ARTIntMap a
  = ARTEmpty
  | ARTLeaf    {-# UNPACK #-} !Int a
  | ARTNode4   {-# UNPACK #-} !Int {-# UNPACK #-} !Int
               {-# UNPACK #-} !(PrimArray Word8)
               {-# UNPACK #-} !(SmallArray (ARTIntMap a))
  | ARTNode16  {-# UNPACK #-} !Int {-# UNPACK #-} !Int
               {-# UNPACK #-} !(PrimArray Word8)
               {-# UNPACK #-} !(SmallArray (ARTIntMap a))
  | ARTNode48  {-# UNPACK #-} !Int {-# UNPACK #-} !Int
               {-# UNPACK #-} !(PrimArray Word8)
               {-# UNPACK #-} !(SmallArray (ARTIntMap a))
  | ARTNode256 {-# UNPACK #-} !Int {-# UNPACK #-} !Int
               {-# UNPACK #-} !(SmallArray (ARTIntMap a))
  deriving (Eq, Show, Functor, Foldable, Traversable)

{-# INLINE emptyART #-}
emptyART :: ARTIntMap a
emptyART = ARTEmpty

{-# INLINE singletonART #-}
singletonART :: Int -> a -> ARTIntMap a
singletonART !k v = ARTLeaf k v

{-# INLINE extractByte #-}
extractByte :: Int -> Int -> Word8
extractByte !k !shiftBits = fromIntegral ((k `unsafeShiftR` shiftBits) .&. 0xFF)

{-# INLINE prefixMatch #-}
prefixMatch :: Int -> Int -> Int -> Bool
prefixMatch !k !pref !shiftBits =
  let !highShift = shiftBits + 8
  in if highShift >= 64
       then True
       else (k `unsafeShiftR` highShift) == (pref `unsafeShiftR` highShift)

-- | O(k) cache-conscious Adaptive Radix Tree lookup.
artLookup :: Int -> ARTIntMap a -> Maybe a
artLookup !_ ARTEmpty = Nothing
artLookup !k (ARTLeaf lk v)
  | k == lk   = Just v
  | otherwise = Nothing
artLookup !k (ARTNode4 pref sh keys children)
  | not (prefixMatch k pref sh) = Nothing
  | otherwise =
      let !b = extractByte k sh
      in case findByteLinear keys b of
           Nothing   -> Nothing
           Just !idx -> artLookup k (indexSmallArray children idx)
artLookup !k (ARTNode16 pref sh keys children)
  | not (prefixMatch k pref sh) = Nothing
  | otherwise =
      let !b = extractByte k sh
      in case findByteLinear keys b of
           Nothing   -> Nothing
           Just !idx -> artLookup k (indexSmallArray children idx)
artLookup !k (ARTNode48 pref sh dirIndex children)
  | not (prefixMatch k pref sh) = Nothing
  | otherwise =
      let !b    = fromIntegral (extractByte k sh) :: Int
          !slot = fromIntegral (indexPrimArray dirIndex b) :: Int
      in if slot == 255
           then Nothing
           else artLookup k (indexSmallArray children slot)
artLookup !k (ARTNode256 pref sh children)
  | not (prefixMatch k pref sh) = Nothing
  | otherwise =
      let !b = fromIntegral (extractByte k sh) :: Int
      in artLookup k (indexSmallArray children b)

{-# INLINE artMember #-}
artMember :: Int -> ARTIntMap a -> Bool
artMember !k !m = case artLookup k m of { Just _ -> True; Nothing -> False }

artInsert :: Int -> a -> ARTIntMap a -> ARTIntMap a
artInsert !k v = artInsertWith const k v

artInsertWith :: (a -> a -> a) -> Int -> a -> ARTIntMap a -> ARTIntMap a
artInsertWith f !k v = go 56
  where
    go !_ ARTEmpty = ARTLeaf k v
    go !sh (ARTLeaf lk lv)
      | k == lk   = ARTLeaf k (f v lv)
      | otherwise = splitLeaves sh k v lk lv
    go !sh node@(ARTNode4 pref nodeSh keys children)
      | not (prefixMatch k pref nodeSh) = branchAbove sh k v pref node
      | otherwise =
          let !b = extractByte k nodeSh
          in case findByteLinear keys b of
               Just !idx ->
                 let !c' = go (nodeSh - 8) (indexSmallArray children idx)
                 in ARTNode4 pref nodeSh keys (replaceSmallSlot children idx c')
               Nothing ->
                 let !n = sizeofPrimArray keys
                     !keys' = appendByte keys b
                     !ch'   = appendSmallSlot children (ARTLeaf k v)
                 in if n < 4
                      then ARTNode4 pref nodeSh keys' ch'
                      else ARTNode16 pref nodeSh keys' ch'
    go !sh node@(ARTNode16 pref nodeSh keys children)
      | not (prefixMatch k pref nodeSh) = branchAbove sh k v pref node
      | otherwise =
          let !b = extractByte k nodeSh
          in case findByteLinear keys b of
               Just !idx ->
                 let !c' = go (nodeSh - 8) (indexSmallArray children idx)
                 in ARTNode16 pref nodeSh keys (replaceSmallSlot children idx c')
               Nothing ->
                 let !n = sizeofPrimArray keys
                 in if n < 16
                      then ARTNode16 pref nodeSh (appendByte keys b) (appendSmallSlot children (ARTLeaf k v))
                      else promote16To48 pref nodeSh keys children b (ARTLeaf k v)
    go !sh node@(ARTNode48 pref nodeSh dir children)
      | not (prefixMatch k pref nodeSh) = branchAbove sh k v pref node
      | otherwise =
          let !b    = fromIntegral (extractByte k nodeSh) :: Int
              !slot = fromIntegral (indexPrimArray dir b) :: Int
          in if slot /= 255
               then
                 let !c' = go (nodeSh - 8) (indexSmallArray children slot)
                 in ARTNode48 pref nodeSh dir (replaceSmallSlot children slot c')
               else
                 let !n = sizeofSmallArray children
                 in if n < 48
                      then
                        let !dir' = updateByte dir b (fromIntegral n)
                            !ch'  = appendSmallSlot children (ARTLeaf k v)
                        in ARTNode48 pref nodeSh dir' ch'
                      else promote48To256 pref nodeSh dir children b (ARTLeaf k v)
    go !sh node@(ARTNode256 pref nodeSh children)
      | not (prefixMatch k pref nodeSh) = branchAbove sh k v pref node
      | otherwise =
          let !b  = fromIntegral (extractByte k nodeSh) :: Int
              !c' = go (nodeSh - 8) (indexSmallArray children b)
          in ARTNode256 pref nodeSh (replaceSmallSlot children b c')

splitLeaves :: Int -> Int -> a -> Int -> a -> ARTIntMap a
splitLeaves !sh !k1 v1 !k2 v2 =
  let findDiffShift !s
        | s <= 0 || extractByte k1 s /= extractByte k2 s = s
        | otherwise = findDiffShift (s - 8)
      !diffSh = findDiffShift sh
      !b1     = extractByte k1 diffSh
      !b2     = extractByte k2 diffSh
  in if b1 < b2
       then ARTNode4 k1 diffSh (primArrayFromList [b1, b2]) (smallArrayFromList [ARTLeaf k1 v1, ARTLeaf k2 v2])
       else ARTNode4 k1 diffSh (primArrayFromList [b2, b1]) (smallArrayFromList [ARTLeaf k2 v2, ARTLeaf k1 v1])

branchAbove :: Int -> Int -> a -> Int -> ARTIntMap a -> ARTIntMap a
branchAbove !sh !k v !pref existing =
  let findDiff !s
        | s <= 0 || extractByte k s /= extractByte pref s = s
        | otherwise = findDiff (s - 8)
      !diffSh = findDiff sh
      !bNew   = extractByte k diffSh
      !bOld   = extractByte pref diffSh
  in if bNew < bOld
       then ARTNode4 k diffSh (primArrayFromList [bNew, bOld]) (smallArrayFromList [ARTLeaf k v, existing])
       else ARTNode4 k diffSh (primArrayFromList [bOld, bNew]) (smallArrayFromList [existing, ARTLeaf k v])

promote16To48 :: Int -> Int -> PrimArray Word8 -> SmallArray (ARTIntMap a) -> Word8 -> ARTIntMap a -> ARTIntMap a
promote16To48 !pref !sh !keys !children !newB !newChild =
  let !dir = runST $ do
        m <- newPrimArray 256
        setPrimArray m 0 256 255
        let loop !i
              | i >= 16 = do
                  writePrimArray m (fromIntegral newB) 16
                  unsafeFreezePrimArray m
              | otherwise = do
                  let !kb = fromIntegral (indexPrimArray keys i) :: Int
                  writePrimArray m kb (fromIntegral i)
                  loop (i + 1)
        loop 0
  in ARTNode48 pref sh dir (appendSmallSlot children newChild)

promote48To256 :: Int -> Int -> PrimArray Word8 -> SmallArray (ARTIntMap a) -> Int -> ARTIntMap a -> ARTIntMap a
promote48To256 !pref !sh !dir !children !newB !newChild =
  let !arr256 = runST $ do
        m <- newSmallArray 256 ARTEmpty
        let loop !b
              | b >= 256 = do
                  writeSmallArray m newB newChild
                  unsafeFreezeSmallArray m
              | otherwise = do
                  let !slot = fromIntegral (indexPrimArray dir b) :: Int
                  if slot /= 255
                    then writeSmallArray m b (indexSmallArray children slot)
                    else pure ()
                  loop (b + 1)
        loop 0
  in ARTNode256 pref sh arr256

artDelete :: Int -> ARTIntMap a -> ARTIntMap a
artDelete !target m =
  artFromList [ (k, v) | (k, v) <- artToList m, k /= target ]

artToList :: ARTIntMap a -> [(Int, a)]
artToList ARTEmpty                     = []
artToList (ARTLeaf k v)                = [(k, v)]
artToList (ARTNode4 _ _ _ children)    = concatMap artToList (smallToList children)
artToList (ARTNode16 _ _ _ children)   = concatMap artToList (smallToList children)
artToList (ARTNode48 _ _ _ children)   = concatMap artToList (smallToList children)
artToList (ARTNode256 _ _ children)    = concatMap artToList (smallToList children)

artFromList :: [(Int, a)] -> ARTIntMap a
artFromList = foldl' (\acc (k, v) -> artInsert k v acc) emptyART

artKeysSet :: ARTIntMap a -> RoaringIntSet
artKeysSet !m = fromListRoaring (map fst (artToList m))

-- Helpers
findByteLinear :: PrimArray Word8 -> Word8 -> Maybe Int
findByteLinear !arr !b =
  let !n = sizeofPrimArray arr
      go !i
        | i >= n    = Nothing
        | indexPrimArray arr i == b = Just i
        | otherwise = go (i + 1)
  in go 0

appendByte :: PrimArray Word8 -> Word8 -> PrimArray Word8
appendByte !arr !b = runST $ do
  let !n = sizeofPrimArray arr
  m <- newPrimArray (n + 1)
  copyPrimArray m 0 arr 0 n
  writePrimArray m n b
  unsafeFreezePrimArray m

updateByte :: PrimArray Word8 -> Int -> Word8 -> PrimArray Word8
updateByte !arr !idx !val = runST $ do
  let !n = sizeofPrimArray arr
  m <- thawPrimArray arr 0 n
  writePrimArray m idx val
  unsafeFreezePrimArray m

replaceSmallSlot :: SmallArray a -> Int -> a -> SmallArray a
replaceSmallSlot !arr !idx !val = runST $ do
  let !n = sizeofSmallArray arr
  m <- thawSmallArray arr 0 n
  writeSmallArray m idx val
  unsafeFreezeSmallArray m

appendSmallSlot :: SmallArray a -> a -> SmallArray a
appendSmallSlot !arr !val = runST $ do
  let !n = sizeofSmallArray arr
  m <- newSmallArray (n + 1) val
  copySmallArray m 0 arr 0 n
  unsafeFreezeSmallArray m

smallToList :: SmallArray a -> [a]
smallToList !arr = [ indexSmallArray arr i | i <- [0 .. sizeofSmallArray arr - 1] ]