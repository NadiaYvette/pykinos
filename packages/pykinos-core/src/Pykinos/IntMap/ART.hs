{-# LANGUAGE BangPatterns, DeriveTraversable #-}

{- |
Module      : Pykinos.IntMap.ART
Description : Adaptive Radix Tree (ART) with 4-tier unboxed fanout
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : EUPL-1.2
Maintainer  : Nadia Chambers <nadia.yvette.chambers@ik.me>
Stability   : experimental
Portability : non-portable (GHC extensions, primitive arrays)

Implements the Adaptive Radix Tree (ART) space-efficient radix tree layout derived from
Leis et al. (ICDE 2013), /"The Adaptive Radix Tree: ARTful Indexing for Main Memory Databases"/.

= Architectural Mechanics

Traditional radix trees (tries) face a trade-off between span width and space consumption:
* Large spans (e.g. 256 children per node) waste significant memory on sparse branches.
* Small spans (e.g. 2 or 4 children) create tall trees requiring excessive pointer hops.

ART solves this dynamically by employing 4 distinct node structures that expand
and adapt dynamically based on child count:

1. **'ARTNode4' (1 to 4 children):**
   Stores up to 4 child pointers alongside an unboxed 4-byte key array. Search executes
   via a linear scan over the 4-byte array.
2. **'ARTNode16' (5 to 16 children):**
   Stores up to 16 child pointers alongside 16 sorted key bytes.
3. **'ARTNode48' (17 to 48 children):**
   Stores a 256-byte direct lookup table mapping byte values to child array indices (0..47),
   using 255 as the empty sentinel. Child pointers reside in a compact 48-element array.
4. **'ARTNode256' (49 to 256 children):**
   Full direct lookup array of 256 child pointers indexed directly by byte value.

= Path Compression

Single-child subtrees are collapsed into path-compressed prefixes ('pref' and 'sh'),
ensuring tree height is bounded strictly by key length (up to 8 bytes for 64-bit 'Int' keys).
-}
module Pykinos.IntMap.ART
  ( -- * ART IntMap Type
    ARTIntMap(..)
    -- * Construction & Empty Maps
  , emptyART
  , singletonART
  , artFromList
    -- * Queries
  , artLookup
  , artMember
  , artToList
  , artKeysSet
    -- * Insertion & Deletion
  , artInsert
  , artInsertWith
  , artDelete
  ) where

import Control.Monad (when)
import Control.Monad.ST (runST)
import Data.Bits ((.&.), unsafeShiftR)
import Data.Primitive.PrimArray
import Data.Primitive.SmallArray
import Data.Word (Word8)
import Pykinos.Bitset.Roaring (RoaringIntSet, fromListRoaring)

-- | Adaptive Radix Tree (ART) IntMap with 4-tier span fanout:
--
--   * 'ARTLeaf'   : Path-compressed single key-value leaf.
--   * 'ARTNode4'  : 1..4 children (unboxed 'Word8' key bytes + 'SmallArray' children).
--   * 'ARTNode16' : 5..16 children (sorted 'Word8' key bytes + 'SmallArray' children).
--   * 'ARTNode48' : 17..48 children (256-byte direct index table + up to 48 children).
--   * 'ARTNode256': 49..256 children (direct 256-slot 'SmallArray').
data ARTIntMap a
  = ARTEmpty
  | ARTLeaf    {-# UNPACK #-} !Int a
    -- ^ Path-compressed leaf storing full 64-bit key and associated value.
  | ARTNode4   {-# UNPACK #-} !Int {-# UNPACK #-} !Int
               {-# UNPACK #-} !(PrimArray Word8)
               {-# UNPACK #-} !(SmallArray (ARTIntMap a))
    -- ^ Small node storing 1..4 child pointers.
  | ARTNode16  {-# UNPACK #-} !Int {-# UNPACK #-} !Int
               {-# UNPACK #-} !(PrimArray Word8)
               {-# UNPACK #-} !(SmallArray (ARTIntMap a))
    -- ^ Medium node storing 5..16 child pointers.
  | ARTNode48  {-# UNPACK #-} !Int {-# UNPACK #-} !Int
               {-# UNPACK #-} !(PrimArray Word8)
               {-# UNPACK #-} !(SmallArray (ARTIntMap a))
    -- ^ Large node storing 17..48 child pointers with 256-byte index map.
  | ARTNode256 {-# UNPACK #-} !Int {-# UNPACK #-} !Int
               {-# UNPACK #-} !(SmallArray (ARTIntMap a))
    -- ^ Full 256-slot direct-indexed radix node.
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | Construct an empty Adaptive Radix Tree.
--
-- Running time: \(O(1)\).
{-# INLINE emptyART #-}
emptyART :: ARTIntMap a
emptyART = ARTEmpty

-- | Construct a single-element Adaptive Radix Tree.
--
-- Running time: \(O(1)\).
{-# INLINE singletonART #-}
singletonART :: Int -> a -> ARTIntMap a
singletonART !k = ARTLeaf k

-- | Extract the relevant byte at bit-shift position 'shiftBits' from key 'k'.
{-# INLINE extractByte #-}
extractByte :: Int -> Int -> Word8
extractByte !k !shiftBits = fromIntegral ((k `unsafeShiftR` shiftBits) .&. 0xFF)

-- | Check whether key 'k' matches the path-compressed prefix of a node.
{-# INLINE prefixMatch #-}
prefixMatch :: Int -> Int -> Int -> Bool
prefixMatch !k !pref !shiftBits =
  let !highShift = shiftBits + 8
  in (highShift >= 64) || ((k `unsafeShiftR` highShift) == (pref `unsafeShiftR` highShift))

-- | Lookup a value associated with key 'k' in the Adaptive Radix Tree.
--
-- Running time: \(O(k)\) where \(k \le 8\) bytes for 64-bit keys.
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
           Just !idx -> artLookup k (indexSmallArray children idx)
           Nothing   -> Nothing
artLookup !k (ARTNode16 pref sh keys children)
  | not (prefixMatch k pref sh) = Nothing
  | otherwise =
      let !b = extractByte k sh
      in case findByteLinear keys b of
           Just !idx -> artLookup k (indexSmallArray children idx)
           Nothing   -> Nothing
artLookup !k (ARTNode48 pref sh dir children)
  | not (prefixMatch k pref sh) = Nothing
  | otherwise =
      let !b = extractByte k sh
          !slot = indexPrimArray dir (fromIntegral b)
      in if slot == 255
           then Nothing
           else artLookup k (indexSmallArray children (fromIntegral slot))
artLookup !k (ARTNode256 pref sh children)
  | not (prefixMatch k pref sh) = Nothing
  | otherwise =
      let !b = extractByte k sh
      in case indexSmallArray children (fromIntegral b) of
           ARTEmpty -> Nothing
           !child   -> artLookup k child

-- | Check whether key 'k' is a member of the Adaptive Radix Tree.
--
-- Running time: \(O(k)\).
{-# INLINE artMember #-}
artMember :: Int -> ARTIntMap a -> Bool
artMember !k !m = case artLookup k m of { Just _ -> True; Nothing -> False }

-- | Insert a key-value association into the ART, replacing any existing value.
--
-- Running time: \(O(k)\) where \(k \le 8\) steps.
artInsert :: Int -> a -> ARTIntMap a -> ARTIntMap a
artInsert !k = artInsertWith const k

-- | Insert with a combining function for resolving existing values.
--
-- Running time: \(O(k)\).
artInsertWith :: (a -> a -> a) -> Int -> a -> ARTIntMap a -> ARTIntMap a
artInsertWith f !k v = go 56
  where
    go !_ ARTEmpty = ARTLeaf k v
    go !sh (ARTLeaf lk lv)
      | k == lk   = ARTLeaf k (f v lv)
      | otherwise = splitLeaves sh k v lk lv
    go !sh node@(ARTNode4 pref nodeSh keys children)
      | not (prefixMatch k pref nodeSh) = splitPrefix sh k v pref nodeSh node
      | otherwise =
          let !b = extractByte k nodeSh
          in case findByteLinear keys b of
               Just !idx ->
                 let !child' = artInsertWith f k v (indexSmallArray children idx)
                 in ARTNode4 pref nodeSh keys (replaceSmallSlot children idx child')
               Nothing ->
                 if sizeofPrimArray keys < 4
                   then
                     let !keys'     = appendByte keys b
                         !children' = appendSmallSlot children (ARTLeaf k v)
                     in ARTNode4 pref nodeSh keys' children'
                   else growNode4To16 pref nodeSh keys children b (ARTLeaf k v)
    go !sh node@(ARTNode16 pref nodeSh keys children)
      | not (prefixMatch k pref nodeSh) = splitPrefix sh k v pref nodeSh node
      | otherwise =
          let !b = extractByte k nodeSh
          in case findByteLinear keys b of
               Just !idx ->
                 let !child' = artInsertWith f k v (indexSmallArray children idx)
                 in ARTNode16 pref nodeSh keys (replaceSmallSlot children idx child')
               Nothing ->
                 if sizeofPrimArray keys < 16
                   then
                     let !keys'     = appendByte keys b
                         !children' = appendSmallSlot children (ARTLeaf k v)
                     in ARTNode16 pref nodeSh keys' children'
                   else growNode16To48 pref nodeSh keys children b (ARTLeaf k v)
    go !sh node@(ARTNode48 pref nodeSh dir children)
      | not (prefixMatch k pref nodeSh) = splitPrefix sh k v pref nodeSh node
      | otherwise =
          let !b = extractByte k nodeSh
              !slot = indexPrimArray dir (fromIntegral b)
          in if slot /= 255
               then
                 let !child' = artInsertWith f k v (indexSmallArray children (fromIntegral slot))
                 in ARTNode48 pref nodeSh dir (replaceSmallSlot children (fromIntegral slot) child')
               else
                 let !cLen = sizeofSmallArray children
                 in if cLen < 48
                      then
                        let !dir'      = updateByte dir (fromIntegral b) (fromIntegral cLen)
                            !children' = appendSmallSlot children (ARTLeaf k v)
                        in ARTNode48 pref nodeSh dir' children'
                      else growNode48To256 pref nodeSh dir children (fromIntegral b) (ARTLeaf k v)
    go !sh node@(ARTNode256 pref nodeSh children)
      | not (prefixMatch k pref nodeSh) = splitPrefix sh k v pref nodeSh node
      | otherwise =
          let !b = fromIntegral (extractByte k nodeSh)
              !oldChild = indexSmallArray children b
              !newChild = case oldChild of
                            ARTEmpty -> ARTLeaf k v
                            _        -> artInsertWith f k v oldChild
          in ARTNode256 pref nodeSh (replaceSmallSlot children b newChild)

-- | Split two conflicting leaves into a shared prefix branch node.
splitLeaves :: Int -> Int -> a -> Int -> a -> ARTIntMap a
splitLeaves !sh !k1 v1 !k2 v2 =
  let go !s
        | s < 0 = ARTLeaf k1 v1
        | otherwise =
            let !b1 = extractByte k1 s
                !b2 = extractByte k2 s
            in if b1 == b2
                 then
                   let !child = go (s - 8)
                   in ARTNode4 k1 s (primArrayFromList [b1]) (smallArrayFromList [child])
                 else
                   let !keys = primArrayFromList [b1, b2]
                       !vals = smallArrayFromList [ARTLeaf k1 v1, ARTLeaf k2 v2]
                   in ARTNode4 k1 s keys vals
  in go sh

-- | Split a node's path prefix when an incoming key diverges.
splitPrefix :: Int -> Int -> a -> Int -> Int -> ARTIntMap a -> ARTIntMap a
splitPrefix !sh !k v !pref !nodeSh !origNode =
  let go !s
        | s <= nodeSh = origNode
        | otherwise =
            let !bNew  = extractByte k s
                !bNode = extractByte pref s
            in if bNew == bNode
                 then
                   let !child = go (s - 8)
                   in ARTNode4 pref s (primArrayFromList [bNode]) (smallArrayFromList [child])
                 else
                   let !keys = primArrayFromList [bNew, bNode]
                       !vals = smallArrayFromList [ARTLeaf k v, origNode]
                   in ARTNode4 pref s keys vals
  in go sh

-- | Expand an overflowing 'ARTNode4' (4 children) into an 'ARTNode16'.
growNode4To16 :: Int -> Int -> PrimArray Word8 -> SmallArray (ARTIntMap a) -> Word8 -> ARTIntMap a -> ARTIntMap a
growNode4To16 !pref !sh !k4 !c4 !newB !newChild =
  let !keys16 = appendByte k4 newB
      !c16    = appendSmallSlot c4 newChild
  in ARTNode16 pref sh keys16 c16

-- | Expand an overflowing 'ARTNode16' (16 children) into an 'ARTNode48'.
growNode16To48 :: Int -> Int -> PrimArray Word8 -> SmallArray (ARTIntMap a) -> Word8 -> ARTIntMap a -> ARTIntMap a
growNode16To48 !pref !sh !k16 !c16 !newB !newChild =
  let !dir = runST $ do
        m <- newPrimArray 256
        setPrimArray m 0 256 (255 :: Word8)
        let !n = sizeofPrimArray k16
        let loop !i
              | i >= n    = pure ()
              | otherwise = do
                  let !b = indexPrimArray k16 i
                  writePrimArray m (fromIntegral b) (fromIntegral i :: Word8)
                  loop (i + 1)
        loop 0
        writePrimArray m (fromIntegral newB) (fromIntegral n :: Word8)
        unsafeFreezePrimArray m
      !c48 = appendSmallSlot c16 newChild
  in ARTNode48 pref sh dir c48

-- | Expand an overflowing 'ARTNode48' (48 children) into an 'ARTNode256'.
growNode48To256 :: Int -> Int -> PrimArray Word8 -> SmallArray (ARTIntMap a) -> Int -> ARTIntMap a -> ARTIntMap a
growNode48To256 !pref !sh !dir !children !newB !newChild =
  let !arr256 = runST $ do
        m <- newSmallArray 256 ARTEmpty
        let loop !b
              | b >= 256 = do
                  writeSmallArray m newB newChild
                  unsafeFreezeSmallArray m
              | otherwise = do
                  let !slot = fromIntegral (indexPrimArray dir b) :: Int
                  when (slot /= 255) $
                    writeSmallArray m b (indexSmallArray children slot)
                  loop (b + 1)
        loop 0
  in ARTNode256 pref sh arr256

-- | Delete a key and its associated value from the Adaptive Radix Tree.
--
-- Running time: \(O(n)\) via rebuild.
artDelete :: Int -> ARTIntMap a -> ARTIntMap a
artDelete !target m =
  artFromList [ (k, v) | (k, v) <- artToList m, k /= target ]

-- | Convert an Adaptive Radix Tree into a list of key-value associations.
--
-- Running time: \(O(n)\).
artToList :: ARTIntMap a -> [(Int, a)]
artToList ARTEmpty                     = []
artToList (ARTLeaf k v)                = [(k, v)]
artToList (ARTNode4 _ _ _ children)    = concatMap artToList (smallToList children)
artToList (ARTNode16 _ _ _ children)   = concatMap artToList (smallToList children)
artToList (ARTNode48 _ _ _ children)   = concatMap artToList (smallToList children)
artToList (ARTNode256 _ _ children)    = concatMap artToList (smallToList children)

-- | Construct an Adaptive Radix Tree from a list of key-value associations.
--
-- Running time: \(O(n \cdot k)\).
artFromList :: [(Int, a)] -> ARTIntMap a
artFromList = foldl' (\acc (k, v) -> artInsert k v acc) emptyART

-- | Extract all keys in the tree into a compressed 'RoaringIntSet'.
--
-- Running time: \(O(n)\).
artKeysSet :: ARTIntMap a -> RoaringIntSet
artKeysSet !m = fromListRoaring (map fst (artToList m))

-- | Linear search for byte 'b' in primitive array.
findByteLinear :: PrimArray Word8 -> Word8 -> Maybe Int
findByteLinear !arr !b =
  let !n = sizeofPrimArray arr
      go !i
        | i >= n    = Nothing
        | indexPrimArray arr i == b = Just i
        | otherwise = go (i + 1)
  in go 0

-- | Append a single byte to an immutable primitive array.
appendByte :: PrimArray Word8 -> Word8 -> PrimArray Word8
appendByte !arr !b = runST $ do
  let !n = sizeofPrimArray arr
  m <- newPrimArray (n + 1)
  copyPrimArray m 0 arr 0 n
  writePrimArray m n b
  unsafeFreezePrimArray m

-- | Update a single byte in a primitive array.
updateByte :: PrimArray Word8 -> Int -> Word8 -> PrimArray Word8
updateByte !arr !idx !val = runST $ do
  let !n = sizeofPrimArray arr
  m <- thawPrimArray arr 0 n
  writePrimArray m idx val
  unsafeFreezePrimArray m

-- | Replace a slot in an immutable SmallArray.
replaceSmallSlot :: SmallArray a -> Int -> a -> SmallArray a
replaceSmallSlot !arr !idx !val = runST $ do
  let !n = sizeofSmallArray arr
  m <- thawSmallArray arr 0 n
  writeSmallArray m idx val
  unsafeFreezeSmallArray m

-- | Append a slot to an immutable SmallArray.
appendSmallSlot :: SmallArray a -> a -> SmallArray a
appendSmallSlot !arr !val = runST $ do
  let !n = sizeofSmallArray arr
  m <- newSmallArray (n + 1) val
  copySmallArray m 0 arr 0 n
  unsafeFreezeSmallArray m

-- | Convert an immutable SmallArray to a list.
smallToList :: SmallArray a -> [a]
smallToList !arr = [ indexSmallArray arr i | i <- [0 .. sizeofSmallArray arr - 1] ]
