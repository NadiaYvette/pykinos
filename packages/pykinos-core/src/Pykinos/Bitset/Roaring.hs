{-# LANGUAGE BangPatterns, UnboxedTuples #-}

{- |
Module      : Pykinos.Bitset.Roaring
Description : Serried Roaring Bitmap with unboxed primitive chunk layout
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : EUPL-1.2
Maintainer  : Nadia Chambers <nadia.yvette.chambers@ik.me>
Stability   : experimental
Portability : non-portable (GHC extensions, primitive arrays)

Implements compressed Roaring Bitmaps based on Chambi, Lemire, Kaser, and Godin (2016),
/"Better alternative to compressed bitmaps: Roaring bitmaps"/.

= Architectural Mechanics

A 32-bit integer \(x \in [0, 2^{32}-1]\) is partitioned into:
* A 16-bit chunk key: \(\text{hi} = \lfloor x / 2^{16} \rfloor\)
* A 16-bit in-chunk offset: \(\text{lo} = x \bmod 2^{16}\)

Within each 16-bit universe of 65,536 integers, data is stored in one of two formats:
1. **'ArrayChunk' (Sparse):** When cardinality \(< 4096\) elements, integers are stored
   as a sorted contiguous 'PrimArray Word16'. Space consumed is \(2 \times \text{cardinality}\) bytes.
2. **'BitmapChunk' (Dense):** When cardinality \(\ge 4096\) elements, integers are stored
   as an unboxed bitset of 1024 64-bit words (8192 bytes = 65,536 bits).

Set operations ('unionRoaring', 'intersectRoaring', 'differenceRoaring') execute via
two-finger merges over sorted chunk keys and utilize bitwise vector primitives for bitmap chunks.
-}
module Pykinos.Bitset.Roaring
  ( -- * Roaring Bitmap Types
    RoaringIntSet(..)
  , RoaringChunk(..)
    -- * Construction & Empty Sets
  , emptyRoaring
  , singletonRoaring
  , fromListRoaring
    -- * Queries & Predicates
  , nullRoaring
  , memberRoaring
  , toListRoaring
  , foldlRoaring'
    -- * Set Algebra
  , insertRoaring
  , deleteRoaring
  , unionRoaring
  , intersectRoaring
  , differenceRoaring
  ) where

import Control.Monad.ST (runST)
import Data.Bits (Bits(..), (.|.), (.&.), shiftL, shiftR, popCount)
import Data.Primitive.PrimArray
import Data.Primitive.SmallArray
import Data.Word (Word16, Word64)

-- | A 16-bit chunk inside a Roaring Bitmap:
--   * 'ArrayChunk' stores sorted 'Word16' offsets when cardinality < 4096.
--   * 'BitmapChunk' stores 1024 'Word64' bitmasks (65536 bits = 8 KB) when dense.
data RoaringChunk
  = ArrayChunk  {-# UNPACK #-} !(PrimArray Word16)
  | BitmapChunk {-# UNPACK #-} !(PrimArray Word64)
  deriving (Eq, Show)

-- | Serried Roaring Bitmap indexed by sorted 16-bit high keys.
--   Key blocks live entirely in unpinned 'PrimArray' memory (zero GC pointer tracing).
data RoaringIntSet = RoaringIntSet
  { risHighKeys :: {-# UNPACK #-} !(PrimArray Word16)
  , risChunks   :: {-# UNPACK #-} !(SmallArray RoaringChunk)
  } deriving (Eq, Show)

{-# INLINE splitKey #-}
splitKey :: Int -> (Word16, Word16)
splitKey !x =
  let !u = fromIntegral x :: Word
  in (fromIntegral (u `shiftR` 16), fromIntegral (u .&. 0xFFFF))

-- | Construct an empty 'RoaringIntSet'.
--
-- Running time: \(O(1)\).
{-# INLINE emptyRoaring #-}
emptyRoaring :: RoaringIntSet
emptyRoaring = RoaringIntSet (primArrayFromList []) (smallArrayFromList [])

-- | Test whether the 'RoaringIntSet' is empty.
--
-- Running time: \(O(1)\).
{-# INLINE nullRoaring #-}
nullRoaring :: RoaringIntSet -> Bool
nullRoaring (RoaringIntSet keys _) = sizeofPrimArray keys == 0

-- | Construct a single-element 'RoaringIntSet'.
--
-- Running time: \(O(1)\).
{-# INLINE singletonRoaring #-}
singletonRoaring :: Int -> RoaringIntSet
singletonRoaring !x =
  let (!hi, !lo) = splitKey x
  in RoaringIntSet
       (primArrayFromList [hi])
       (smallArrayFromList [ArrayChunk (primArrayFromList [lo])])

-- | Binary search over an unboxed 'PrimArray Word16'.
binarySearchW16 :: PrimArray Word16 -> Word16 -> Either Int Int
binarySearchW16 !arr !target = go 0 (sizeofPrimArray arr - 1)
  where
    go !lo !hi
      | lo > hi   = Left lo
      | otherwise =
          let !mid = (lo + hi) ` unsafeShiftR` 1
              !v   = indexPrimArray arr mid
          in if v == target
               then Right mid
               else if v < target
                 then go (mid + 1) hi
                 else go lo (mid - 1)

{-# INLINE memberRoaring #-}
memberRoaring :: Int -> RoaringIntSet -> Bool
memberRoaring !x (RoaringIntSet keys chunks) =
  let (!hi, !lo) = splitKey x
  in case binarySearchW16 keys hi of
       Left _     -> False
       Right !idx ->
         case indexSmallArray chunks idx of
           ArrayChunk arr ->
             case binarySearchW16 arr lo of
               Right _ -> True
               Left _  -> False
           BitmapChunk bmap ->
             let !wordIdx = fromIntegral lo `unsafeShiftR` 6
                 !bitIdx  = fromIntegral lo .&. 63
                 !w       = indexPrimArray bmap wordIdx
             in (w .&. (1 `unsafeShiftL` bitIdx)) /= 0

insertRoaring :: Int -> RoaringIntSet -> RoaringIntSet
insertRoaring !x r@(RoaringIntSet keys chunks) =
  let (!hi, !lo) = splitKey x
  in case binarySearchW16 keys hi of
       Left !insIdx ->
         let !newKeys   = insertPrimW16 keys insIdx hi
             !newChunk  = ArrayChunk (primArrayFromList [lo])
             !newChunks = insertSmall chunks insIdx newChunk
         in RoaringIntSet newKeys newChunks
       Right !idx ->
         let !oldChunk = indexSmallArray chunks idx
             !updChunk = insertIntoChunk lo oldChunk
         in if updChunk == oldChunk
              then r
              else RoaringIntSet keys (replaceSmall chunks idx updChunk)

insertIntoChunk :: Word16 -> RoaringChunk -> RoaringChunk
insertIntoChunk !lo (ArrayChunk arr) =
  case binarySearchW16 arr lo of
    Right _     -> ArrayChunk arr
    Left !insAt ->
      let !arr' = insertPrimW16 arr insAt lo
      in if sizeofPrimArray arr' >= 4096
           then arrayToBitmap arr'
           else ArrayChunk arr'
insertIntoChunk !lo (BitmapChunk bmap) = runST $ do
  let !wIdx = fromIntegral lo `unsafeShiftR` 6
      !bIdx = fromIntegral lo .&. 63
      !oldW = indexPrimArray bmap wIdx
      !newW = oldW .|. (1 `unsafeShiftL` bIdx)
  if oldW == newW
    then pure (BitmapChunk bmap)
    else do
      m <- thawPrimArray bmap 0 1024
      writePrimArray m wIdx newW
      BitmapChunk <$> unsafeFreezePrimArray m

deleteRoaring :: Int -> RoaringIntSet -> RoaringIntSet
deleteRoaring !x r@(RoaringIntSet keys chunks) =
  let (!hi, !lo) = splitKey x
  in case binarySearchW16 keys hi of
       Left _     -> r
       Right !idx ->
         case deleteFromChunk lo (indexSmallArray chunks idx) of
           Nothing       -> RoaringIntSet (deletePrimW16 keys idx) (deleteSmall chunks idx)
           Just !chunk'  -> RoaringIntSet keys (replaceSmall chunks idx chunk')

deleteFromChunk :: Word16 -> RoaringChunk -> Maybe RoaringChunk
deleteFromChunk !lo (ArrayChunk arr) =
  case binarySearchW16 arr lo of
    Left _ -> Just (ArrayChunk arr)
    Right !i
      | sizeofPrimArray arr <= 1 -> Nothing
      | otherwise                -> Just (ArrayChunk (deletePrimW16 arr i))
deleteFromChunk !lo (BitmapChunk bmap) =
  let !wIdx = fromIntegral lo `unsafeShiftR` 6
      !bIdx = fromIntegral lo .&. 63
      !oldW = indexPrimArray bmap wIdx
      !newW = oldW .&. complement (1 `unsafeShiftL` bIdx)
  in if oldW == newW
       then Just (BitmapChunk bmap)
       else
         let !bmap' = runST $ do
               m <- thawPrimArray bmap 0 1024
               writePrimArray m wIdx newW
               unsafeFreezePrimArray m
             !pop = popCountBitmap bmap'
         in if pop == 0
              then Nothing
              else if pop < 4096
                then Just (bitmapToArray bmap')
                else Just (BitmapChunk bmap')

-- | Two-finger merge union over sorted 16-bit chunk keys.
unionRoaring :: RoaringIntSet -> RoaringIntSet -> RoaringIntSet
unionRoaring (RoaringIntSet kA cA) (RoaringIntSet kB cB) =
  let !nA = sizeofPrimArray kA
      !nB = sizeofPrimArray kB
      go !i !j !accK !accC
        | i >= nA && j >= nB =
            RoaringIntSet (primArrayFromList (reverse accK)) (smallArrayFromList (reverse accC))
        | i >= nA =
            go i (j + 1) (indexPrimArray kB j : accK) (indexSmallArray cB j : accC)
        | j >= nB =
            go (i + 1) j (indexPrimArray kA i : accK) (indexSmallArray cA i : accC)
        | otherwise =
            let !hiA = indexPrimArray kA i
                !hiB = indexPrimArray kB j
            in case compare hiA hiB of
                 LT -> go (i + 1) j (hiA : accK) (indexSmallArray cA i : accC)
                 GT -> go i (j + 1) (hiB : accK) (indexSmallArray cB j : accC)
                 EQ ->
                   let !merged = unionChunk (indexSmallArray cA i) (indexSmallArray cB j)
                   in go (i + 1) (j + 1) (hiA : accK) (merged : accC)
  in go 0 0 [] []

unionChunk :: RoaringChunk -> RoaringChunk -> RoaringChunk
unionChunk (BitmapChunk bA) (BitmapChunk bB) = BitmapChunk $ runST $ do
  m <- newPrimArray 1024
  let loop !k
        | k >= 1024 = unsafeFreezePrimArray m
        | otherwise = do
            writePrimArray m k (indexPrimArray bA k .|. indexPrimArray bB k)
            loop (k + 1)
  loop 0
unionChunk (ArrayChunk aA) (BitmapChunk bB) =
  unionChunk (arrayToBitmap aA) (BitmapChunk bB)
unionChunk (BitmapChunk bA) (ArrayChunk aB) =
  unionChunk (BitmapChunk bA) (arrayToBitmap aB)
unionChunk (ArrayChunk aA) (ArrayChunk aB) =
  let !u = mergeSortedW16 aA aB
  in if sizeofPrimArray u >= 4096 then arrayToBitmap u else ArrayChunk u

-- | High-speed chunk intersection.
intersectRoaring :: RoaringIntSet -> RoaringIntSet -> RoaringIntSet
intersectRoaring (RoaringIntSet kA cA) (RoaringIntSet kB cB) =
  let !nA = sizeofPrimArray kA
      !nB = sizeofPrimArray kB
      go !i !j !accK !accC
        | i >= nA || j >= nB =
            RoaringIntSet (primArrayFromList (reverse accK)) (smallArrayFromList (reverse accC))
        | otherwise =
            let !hiA = indexPrimArray kA i
                !hiB = indexPrimArray kB j
            in case compare hiA hiB of
                 LT -> go (i + 1) j accK accC
                 GT -> go i (j + 1) accK accC
                 EQ ->
                   case intersectChunk (indexSmallArray cA i) (indexSmallArray cB j) of
                     Nothing  -> go (i + 1) (j + 1) accK accC
                     Just !ch -> go (i + 1) (j + 1) (hiA : accK) (ch : accC)
  in go 0 0 [] []

intersectChunk :: RoaringChunk -> RoaringChunk -> Maybe RoaringChunk
intersectChunk (BitmapChunk bA) (BitmapChunk bB) =
  let !bOut = runST $ do
        m <- newPrimArray 1024
        let loop !k
              | k >= 1024 = unsafeFreezePrimArray m
              | otherwise = do
                  writePrimArray m k (indexPrimArray bA k .&. indexPrimArray bB k)
                  loop (k + 1)
        loop 0
      !pop = popCountBitmap bOut
  in if pop == 0
       then Nothing
       else if pop < 4096
         then Just (bitmapToArray bOut)
         else Just (BitmapChunk bOut)
intersectChunk (ArrayChunk aA) (ArrayChunk aB) =
  let !inter = intersectSortedW16 aA aB
  in if sizeofPrimArray inter == 0 then Nothing else Just (ArrayChunk inter)
intersectChunk (ArrayChunk a) b@(BitmapChunk _) =
  let !filtered = filterW16 (`memberChunk` b) a
  in if sizeofPrimArray filtered == 0 then Nothing else Just (ArrayChunk filtered)
intersectChunk a@(BitmapChunk _) (ArrayChunk b) =
  intersectChunk (ArrayChunk b) a

-- | Two-finger difference over sorted 16-bit chunk keys.
differenceRoaring :: RoaringIntSet -> RoaringIntSet -> RoaringIntSet
differenceRoaring (RoaringIntSet kA cA) (RoaringIntSet kB cB) =
  let !nA = sizeofPrimArray kA
      !nB = sizeofPrimArray kB
      go !i !j !accK !accC
        | i >= nA =
            RoaringIntSet (primArrayFromList (reverse accK)) (smallArrayFromList (reverse accC))
        | j >= nB =
            go (i + 1) j (indexPrimArray kA i : accK) (indexSmallArray cA i : accC)
        | otherwise =
            let !hiA = indexPrimArray kA i
                !hiB = indexPrimArray kB j
            in case compare hiA hiB of
                 LT -> go (i + 1) j (hiA : accK) (indexSmallArray cA i : accC)
                 GT -> go i (j + 1) accK accC
                 EQ ->
                   case diffChunk (indexSmallArray cA i) (indexSmallArray cB j) of
                     Nothing  -> go (i + 1) (j + 1) accK accC
                     Just !ch -> go (i + 1) (j + 1) (hiA : accK) (ch : accC)
  in go 0 0 [] []

diffChunk :: RoaringChunk -> RoaringChunk -> Maybe RoaringChunk
diffChunk (ArrayChunk aA) bB =
  let !filtered = filterW16 (\lo -> not (memberChunk lo bB)) aA
  in if sizeofPrimArray filtered == 0 then Nothing else Just (ArrayChunk filtered)
diffChunk (BitmapChunk bA) (ArrayChunk aB) =
  let !bOut = runST $ do
        m <- thawPrimArray bA 0 1024
        let !n = sizeofPrimArray aB
            loop !i
              | i >= n = unsafeFreezePrimArray m
              | otherwise = do
                  let !lo = indexPrimArray aB i
                      !wIdx = fromIntegral lo `unsafeShiftR` 6
                      !bIdx = fromIntegral lo .&. 63
                  oldW <- readPrimArray m wIdx
                  writePrimArray m wIdx (oldW .&. complement (1 `unsafeShiftL` bIdx))
                  loop (i + 1)
        loop 0
      !pop = popCountBitmap bOut
  in if pop == 0
       then Nothing
       else if pop < 4096
         then Just (bitmapToArray bOut)
         else Just (BitmapChunk bOut)
diffChunk (BitmapChunk bA) (BitmapChunk bB) =
  let !bOut = runST $ do
        m <- newPrimArray 1024
        let loop !k
              | k >= 1024 = unsafeFreezePrimArray m
              | otherwise = do
                  writePrimArray m k (indexPrimArray bA k .&. complement (indexPrimArray bB k))
                  loop (k + 1)
        loop 0
      !pop = popCountBitmap bOut
  in if pop == 0
       then Nothing
       else if pop < 4096
         then Just (bitmapToArray bOut)
         else Just (BitmapChunk bOut)

fromListRoaring :: [Int] -> RoaringIntSet
fromListRoaring = foldl' (flip insertRoaring) emptyRoaring

toListRoaring :: RoaringIntSet -> [Int]
toListRoaring (RoaringIntSet keys chunks) =
  let !n = sizeofPrimArray keys
      chunkToList !hi (ArrayChunk arr) =
        let !m = sizeofPrimArray arr
        in [ combineKey hi (indexPrimArray arr i) | i <- [0 .. m - 1] ]
      chunkToList !hi (BitmapChunk bmap) =
        [ combineKey hi (fromIntegral ((wIdx `unsafeShiftL` 6) .|. bIdx))
        | wIdx <- [0 .. 1023]
        , let !w = indexPrimArray bmap wIdx
        , w /= 0
        , bIdx <- [0 .. 63]
        , (w .&. (1 `unsafeShiftL` bIdx)) /= 0
        ]
  in concat [ chunkToList (indexPrimArray keys i) (indexSmallArray chunks i) | i <- [0 .. n - 1] ]

{-# INLINE combineKey #-}
combineKey :: Word16 -> Word16 -> Int
combineKey !hi !lo =
  fromIntegral ((fromIntegral hi `shiftL` 16) .|. (fromIntegral lo :: Word))

foldlRoaring' :: (a -> Int -> a) -> a -> RoaringIntSet -> a
foldlRoaring' f !z0 !r = foldl' f z0 (toListRoaring r)

-- Helpers

memberChunk :: Word16 -> RoaringChunk -> Bool
memberChunk !lo (ArrayChunk arr) =
  case binarySearchW16 arr lo of
    Right _ -> True
    Left _  -> False
memberChunk !lo (BitmapChunk bmap) =
  let !wIdx = fromIntegral lo `unsafeShiftR` 6
      !bIdx = fromIntegral lo .&. 63
      !w    = indexPrimArray bmap wIdx
  in (w .&. (1 `unsafeShiftL` bIdx)) /= 0

insertPrimW16 :: PrimArray Word16 -> Int -> Word16 -> PrimArray Word16
insertPrimW16 !arr !idx !val = runST $ do
  let !n = sizeofPrimArray arr
  m <- newPrimArray (n + 1)
  copyPrimArray m 0 arr 0 idx
  writePrimArray m idx val
  copyPrimArray m (idx + 1) arr idx (n - idx)
  unsafeFreezePrimArray m

deletePrimW16 :: PrimArray Word16 -> Int -> PrimArray Word16
deletePrimW16 !arr !idx = runST $ do
  let !n = sizeofPrimArray arr
  m <- newPrimArray (n - 1)
  copyPrimArray m 0 arr 0 idx
  copyPrimArray m idx arr (idx + 1) (n - idx - 1)
  unsafeFreezePrimArray m

insertSmall :: SmallArray a -> Int -> a -> SmallArray a
insertSmall !arr !idx val = runST $ do
  let !n = sizeofSmallArray arr
  m <- newSmallArray (n + 1) val
  copySmallArray m 0 arr 0 idx
  writeSmallArray m idx val
  copySmallArray m (idx + 1) arr idx (n - idx)
  unsafeFreezeSmallArray m

deleteSmall :: SmallArray a -> Int -> SmallArray a
deleteSmall !arr !idx = runST $ do
  let !n = sizeofSmallArray arr
  m <- newSmallArray (n - 1) (indexSmallArray arr (if idx == 0 then 1 else 0))
  copySmallArray m 0 arr 0 idx
  copySmallArray m idx arr (idx + 1) (n - idx - 1)
  unsafeFreezeSmallArray m

replaceSmall :: SmallArray a -> Int -> a -> SmallArray a
replaceSmall !arr !idx val = runST $ do
  let !n = sizeofSmallArray arr
  m <- thawSmallArray arr 0 n
  writeSmallArray m idx val
  unsafeFreezeSmallArray m

arrayToBitmap :: PrimArray Word16 -> RoaringChunk
arrayToBitmap !arr = runST $ do
  m <- newPrimArray 1024
  setPrimArray m 0 1024 0
  let !n = sizeofPrimArray arr
      loop !i
        | i >= n = BitmapChunk <$> unsafeFreezePrimArray m
        | otherwise = do
            let !lo = indexPrimArray arr i
                !wIdx = fromIntegral lo `unsafeShiftR` 6
                !bIdx = fromIntegral lo .&. 63
            oldW <- readPrimArray m wIdx
            writePrimArray m wIdx (oldW .|. (1 `unsafeShiftL` bIdx))
            loop (i + 1)
  loop 0

bitmapToArray :: PrimArray Word64 -> RoaringChunk
bitmapToArray !bmap =
  let !elements = [ fromIntegral ((wIdx `unsafeShiftL` 6) .|. bIdx) :: Word16
                  | wIdx <- [0..1023]
                  , let !w = indexPrimArray bmap wIdx
                  , w /= 0
                  , bIdx <- [0..63]
                  , (w .&. (1 `unsafeShiftL` bIdx)) /= 0
                  ]
  in ArrayChunk (primArrayFromList elements)

popCountBitmap :: PrimArray Word64 -> Int
popCountBitmap !bmap =
  let go !i !acc
        | i >= 1024 = acc
        | otherwise = go (i + 1) (acc + popCount (indexPrimArray bmap i))
  in go 0 0

mergeSortedW16 :: PrimArray Word16 -> PrimArray Word16 -> PrimArray Word16
mergeSortedW16 !aA !aB =
  let !nA = sizeofPrimArray aA
      !nB = sizeofPrimArray aB
      go !i !j !acc
        | i >= nA && j >= nB = primArrayFromList (reverse acc)
        | i >= nA = go i (j + 1) (indexPrimArray aB j : acc)
        | j >= nB = go (i + 1) j (indexPrimArray aA i : acc)
        | otherwise =
            let !vA = indexPrimArray aA i
                !vB = indexPrimArray aB j
            in case compare vA vB of
                 LT -> go (i + 1) j (vA : acc)
                 GT -> go i (j + 1) (vB : acc)
                 EQ -> go (i + 1) (j + 1) (vA : acc)
  in go 0 0 []

intersectSortedW16 :: PrimArray Word16 -> PrimArray Word16 -> PrimArray Word16
intersectSortedW16 !aA !aB =
  let !nA = sizeofPrimArray aA
      !nB = sizeofPrimArray aB
      go !i !j !acc
        | i >= nA || j >= nB = primArrayFromList (reverse acc)
        | otherwise =
            let !vA = indexPrimArray aA i
                !vB = indexPrimArray aB j
            in case compare vA vB of
                 LT -> go (i + 1) j acc
                 GT -> go i (j + 1) acc
                 EQ -> go (i + 1) (j + 1) (vA : acc)
  in go 0 0 []

filterW16 :: (Word16 -> Bool) -> PrimArray Word16 -> PrimArray Word16
filterW16 p !arr =
  let !n = sizeofPrimArray arr
      go !i !acc
        | i >= n    = primArrayFromList (reverse acc)
        | otherwise =
            let !v = indexPrimArray arr i
            in if p v then go (i + 1) (v : acc) else go (i + 1) acc
  in go 0 []
