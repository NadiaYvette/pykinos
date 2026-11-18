{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE UnboxedTuples #-}

-- |
-- Module      : Pykinos.Mutable.SwissTable
-- Description : Zero-GC SWAR open-addressed hash-consing table over MutableByteArray#.
--
-- Maps 128-bit unboxed keys @(Word64, Word64)@ to 32-bit unboxed IDs ('Int32')
-- with 8-slot SWAR parallel control probing and zero boxed heap pointers.
module Pykinos.Mutable.SwissTable
  ( SwissTable128(..)
  , newSwissTable128
  , lookupOrInsert128
  , packNfNode128
  , matchH2Swar64
  ) where

import Control.Monad (when)
import Control.Monad.ST (ST)
import Data.Bits
  ( complement
  , countTrailingZeros
  , unsafeShiftL
  , unsafeShiftR
  , xor
  , (.&.)
  , (.|.)
  )
import Data.Int (Int32)
import Data.Primitive.ByteArray
  ( MutableByteArray(..)
  , newByteArray
  , readByteArray
  , setByteArray
  , writeByteArray
  )
import Data.Word (Word8, Word32, Word64)
import GHC.Exts (Int(..), readWord8ArrayAsWord64#)
import GHC.Word (Word64(W64#))
import GHC.ST (ST(..))

-- | Open-addressed SwissTable with mutable unboxed slabs wrapped in a 4-slot descriptor.
--   Because all slabs are 'MutableByteArray', GHC's GC never scans the table entries.
data SwissTable128 s = SwissTable128
  { stArrays :: !(MutableByteArray s)
    -- ^ Int32[0] = count, Int32[1] = cap, Int32[2] = maxLoad
  , stCtrlRef :: !(SmallRef s (MutableByteArray s))
  , stKeysRef :: !(SmallRef s (MutableByteArray s))
  , stValsRef :: !(SmallRef s (MutableByteArray s))
  }

-- | Lightweight 1-slot mutable box for swapping grown ByteArrays.
newtype SmallRef s a = SmallRef (MutableByteArray s)

ctrlEmpty :: Word8
ctrlEmpty = 0x80

-- | Allocate a power-of-two 'SwissTable128' (minimum capacity 16).
newSwissTable128 :: Int -> ST s (SwissTable128 s)
newSwissTable128 !reqCap = do
  let !cap     = nextPow2 (max 16 reqCap)
      !maxLoad = (cap * 7) `unsafeShiftR` 3
  ctrl <- newByteArray (cap + 8)
  setByteArray ctrl 0 (cap + 8) ctrlEmpty
  keys <- newByteArray (cap * 16)
  vals <- newByteArray (cap * 4)
  st   <- newByteArray 12
  writeByteArray st 0 (0 :: Int32)
  writeByteArray st 1 (fromIntegral cap :: Int32)
  writeByteArray st 2 (fromIntegral maxLoad :: Int32)
  pure (SwissTable128 st (SmallRef ctrl) (SmallRef keys) (SmallRef vals))

nextPow2 :: Int -> Int
nextPow2 !n = go 16
  where
    go !p | p >= n    = p
          | otherwise = go (p `unsafeShiftL` 1)

{-# INLINE hash128 #-}
hash128 :: Word64 -> Word64 -> Word64
hash128 !kLo !kHi =
  let !h0 = (kLo `xor` (kHi * 0x9E3779B97F4A7C15)) * 0xBF58476D1CE4E5B9
      !h1 = (h0 `xor` (h0 `unsafeShiftR` 30)) * 0x94D049BB133111EB
  in h1 `xor` (h1 `unsafeShiftR` 31)

{-# INLINE readCtrlGroup64 #-}
readCtrlGroup64 :: MutableByteArray s -> Int -> ST s Word64
readCtrlGroup64 (MutableByteArray mba#) (I# slot#) = ST $ \s0 ->
  case readWord8ArrayAsWord64# mba# slot# s0 of
    (# s1, w# #) -> (# s1, W64# w# #)

{-# INLINE writeCtrlByte #-}
writeCtrlByte :: MutableByteArray s -> Int -> Int -> Word8 -> ST s ()
writeCtrlByte !ctrl !cap !slot !b = do
  writeByteArray ctrl slot b
  when (slot < 8) $
    writeByteArray ctrl (cap + slot) b

-- | Borrow-free SWAR match returning bit (8*i + 7) == 1 iff byte i equals h2.
{-# INLINE matchH2Swar64 #-}
matchH2Swar64 :: Word64 -> Word8 -> Word64
matchH2Swar64 !ctrlWord !h2 =
  let !pat  = 0x0101010101010101 * fromIntegral h2
      !x    = ctrlWord `xor` pat
      !low7 = (x .&. 0x7F7F7F7F7F7F7F7F) + 0x7F7F7F7F7F7F7F7F
  in complement (low7 .|. x .|. 0x7F7F7F7F7F7F7F7F)

{-# INLINE matchEmptySwar64 #-}
matchEmptySwar64 :: Word64 -> Word64
matchEmptySwar64 !ctrlWord = ctrlWord .&. 0x8080808080808080

-- | Lookup or insert a 128-bit key, returning its dense monotonic Int32 ID.
{-# INLINE lookupOrInsert128 #-}
lookupOrInsert128
  :: SwissTable128 s
  -> Word64
  -> Word64
  -> ST s Int32
lookupOrInsert128 SwissTable128{..} !keyLo !keyHi = do
  let SmallRef ctrl = stCtrlRef
      SmallRef keys = stKeysRef
      SmallRef vals = stValsRef
  cap32 :: Int32 <- readByteArray stArrays 1
  let !cap  = fromIntegral cap32 :: Int
      !mask = cap - 1
      !h    = hash128 keyLo keyHi
      !h1   = fromIntegral (h `unsafeShiftR` 7) :: Int
      !h2   = fromIntegral (h .&. 0x7F) :: Word8

      probeGroup !groupStart !step = do
        !ctrlWord <- readCtrlGroup64 ctrl groupStart
        let !hitMask = matchH2Swar64 ctrlWord h2
        mbFound <- checkHits groupStart mask hitMask
        case mbFound of
          Just existingVal -> pure existingVal
          Nothing -> do
            let !empMask = matchEmptySwar64 ctrlWord
            if empMask /= 0
              then do
                let !byteIdx = countTrailingZeros empMask `unsafeShiftR` 3
                    !slot    = (groupStart + byteIdx) .&. mask
                cnt :: Int32 <- readByteArray stArrays 0
                writeByteArray stArrays 0 (cnt + 1)
                writeCtrlByte ctrl cap slot h2
                writeByteArray keys (slot * 2)     keyLo
                writeByteArray keys (slot * 2 + 1) keyHi
                writeByteArray vals slot           cnt
                pure cnt
              else
                probeGroup ((groupStart + step) .&. mask) (step + 8)

      checkHits !groupStart !msk !m
        | m == 0 = pure Nothing
        | otherwise = do
            let !byteIdx = countTrailingZeros m `unsafeShiftR` 3
                !slot    = (groupStart + byteIdx) .&. msk
            !kLo <- readByteArray keys (slot * 2)
            !kHi <- readByteArray keys (slot * 2 + 1)
            if kLo == keyLo && kHi == keyHi
              then Just <$> readByteArray vals slot
              else checkHits groupStart msk (m .&. (m - 1))

  probeGroup (h1 .&. mask) 8

-- | Pack a fixed-arity normal-form DAG node into a 128-bit SwissTable key.
{-# INLINE packNfNode128 #-}
packNfNode128 :: Word8 -> Word32 -> Int32 -> Int32 -> Int32 -> (Word64, Word64)
packNfNode128 !tag !aux !cA !cB !cC =
  let !lo = (fromIntegral tag `unsafeShiftL` 56)
        .|. (fromIntegral (aux .&. 0x00FFFFFF) `unsafeShiftL` 32)
        .|. fromIntegral (fromIntegral cA :: Word32)
      !hi = (fromIntegral (fromIntegral cB :: Word32) `unsafeShiftL` 32)
        .|. fromIntegral (fromIntegral cC :: Word32)
  in (lo, hi)
