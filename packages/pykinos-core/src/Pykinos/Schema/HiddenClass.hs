{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : Pykinos.Schema.HiddenClass
-- Description : Order-preserving symbol lexicon and 3-way dynamic record MergeMorphs.
--
-- Eliminates dynamic @Map Text Expr@ trees by interning field names into
-- rank-ordered 'FieldId's and representing record shapes as interned 'SchemaId's
-- with precomputed 3-way 'MergeMorph3' gather plans.
--
-- === Architectural Rationale
--
-- Traditional AST record representations in interpreters (such as Dhall and 1ML)
-- use unbalanced search trees or associative maps. When performing record operations
-- (such as record merge @//@, deep meet @/\\@, or signature projection @:>@), every
-- operation traverses pointer-heavy tree structures, resulting in significant GC
-- pressure and branch mispredictions.
--
-- By decoupling the field names into a frozen, rank-ordered 'Lexicon' and mapping
-- field sets into contiguous sorted 'PrimArray's of 'Word32's ('SchemaId'), record
-- merge operations become pure array-to-array linear scans synthesized in $O(N_1 + N_2)$
-- time into unboxed 64-bit gather codes ('MergeMorph3').
--
-- === 3-Way Gather Code Representation
--
-- Each gather code in 'MergeMorph3' is an unboxed 'Int64':
--
--   1. Positive values (@code >= 0@): The field is copied directly from slot
--      @code@ of the left record.
--   2. Negative values with bit 62 clear (@code < 0@, @bit 62 == 0@): The field
--      is copied directly from slot @complement code@ of the right record.
--   3. Negative values with bit 62 set (@code < 0@, @bit 62 == 1@): Both records
--      contain the field. A collision has occurred that must be resolved via
--      recursive normalization (for 'OpCombineDeep'). The two source slot indices
--      @(idx1, idx2)@ are packed into bits 0..59.
module Pykinos.Schema.HiddenClass
  ( -- * Field and Schema Identifiers
    FieldId(..)
  , SchemaId(..)

    -- * Dynamic Record Operations
  , RecordOp(..)
  , MergeMorph3(..)

    -- * Symbol Lexicon
  , Lexicon(..)
  , buildLexicon
  , lookupFieldId
  , lookupFieldText

    -- * Slot Search and Gather Code Encoding
  , findFieldSlot
  , collisionBit3
  , encodeRightSlot3
  , encodeCollision3
  , decodeMergeCode3

    -- * Linear Merge Synthesis
  , synthesizeMergeMorph3
  ) where

import Data.Bits (complement, shiftL, shiftR, unsafeShiftR, (.&.), (.|.))
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Primitive.PrimArray
  ( PrimArray
  , indexPrimArray
  , primArrayFromList
  , sizeofPrimArray
  )
import Data.Primitive.SmallArray
  ( SmallArray
  , indexSmallArray
  , smallArrayFromList
  )
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word32)

-- | Rank-ordered 32-bit field identifier.
--
-- Invariant: For all field identifiers @fid1@ and @fid2@,
-- @fid1 < fid2@ holds if and only if @text(fid1) < text(fid2)@ in standard
-- lexicographical UTF-8 byte order. This invariant guarantees that sorting by
-- 'FieldId' is completely isomorphic to sorting by record label 'Text'.
newtype FieldId = FieldId { unFieldId :: Word32 }
  deriving newtype (Eq, Ord, Show)

-- | Interned 32-bit identifier for a sorted 'PrimArray' of 'FieldId's.
--
-- A 'SchemaId' represents the immutable structural type of a record. Two records
-- share the same 'SchemaId' if and only if they possess identical field sets in
-- identical order.
newtype SchemaId = SchemaId { unSchemaId :: Word32 }
  deriving newtype (Eq, Ord, Show)

-- | Dynamic record algebra operations supported by 'MergeMorph3'.
--
-- These correspond to the fundamental record combinators in languages with
-- first-class records and modules:
data RecordOp
  = OpPreferR
    -- ^ Right-biased override union. When a label appears in both records,
    -- the value from the right-hand record overwrites the left-hand record.
    -- Corresponds to Dhall's @//@ and 1ML structure @include@.
  | OpCombineDeep
    -- ^ Recursive deep meet. When a label appears in both records,
    -- the two values collide and must be recursively merged.
    -- Corresponds to Dhall's @/\\@ and 1ML signature sharing.
  | OpRestrict
    -- ^ Domain restriction / projection. Restricts the fields of the left
    -- record to the schema defined by the right record.
    -- Corresponds to 1ML existential sealing (@Mod :> Sig@).
  deriving (Eq, Ord, Show)

-- | 3-way gather plan encoded in an unboxed 'PrimArray' of 'Int64' codes.
--
-- The array length matches the number of fields in the resulting merged record.
-- Each slot contains an instruction specifying how the target value is obtained:
--
--   * @code >= 0@              : copy slot @code@ from left record
--   * @code < 0, bit 62 == 0@  : copy slot @complement code@ from right record
--   * @code < 0, bit 62 == 1@  : lazy deep-meet collision on @(idx1, idx2)@
newtype MergeMorph3 = MergeMorph3 { unMergeMorph3 :: PrimArray Int64 }
  deriving (Eq, Show)

-- | Frozen rank-ordered lexicon mapping 'Text' labels to 'FieldId's.
--
-- Provides bidirectional O(log L) lookup from 'Text' to 'FieldId' and
-- O(1) indexed recovery from 'FieldId' back to 'Text'.
data Lexicon = Lexicon
  { lexToId   :: !(Map.Map Text FieldId)
    -- ^ Forward index mapping unique text labels to rank-ordered field IDs.
  , lexToText :: !(SmallArray Text)
    -- ^ Reverse index enabling O(1) term reconstruction during pretty-printing.
  }
  deriving (Show)

-- | Construct a rank-ordered 'Lexicon' from all field labels appearing in an AST.
--
-- Collects all unique labels, sorts them into strictly ascending order, and assigns
-- zero-based sequential 'Word32' identifiers.
buildLexicon :: [Text] -> Lexicon
buildLexicon rawLabels =
  let sortedUnique = Set.toAscList (Set.fromList rawLabels)
      pairs        = zip sortedUnique [FieldId i | i <- [0 ..]]
  in Lexicon
       { lexToId   = Map.fromDistinctAscList pairs
       , lexToText = smallArrayFromList sortedUnique
       }

-- | Resolve a 'Text' label to its rank-ordered 'FieldId' in O(log L) time.
{-# INLINE lookupFieldId #-}
lookupFieldId :: Lexicon -> Text -> Maybe FieldId
lookupFieldId Lexicon{..} !txt = Map.lookup txt lexToId

-- | Recover the original 'Text' label from a 'FieldId' in strictly O(1) time.
{-# INLINE lookupFieldText #-}
lookupFieldText :: Lexicon -> FieldId -> Text
lookupFieldText Lexicon{..} (FieldId !w) =
  indexSmallArray lexToText (fromIntegral w)

-- | Bit 62 distinguishes a right-record slot from a two-record deep collision.
-- Bit 63 is the sign bit (1 for negative numbers). Bit 62 serves as the discriminator flag.
collisionBit3 :: Int64
collisionBit3 = 1 `shiftL` 62

-- | Encode a right-record slot index @idx2@ as a negative 'Int64' with bit 62 clear.
--
-- Uses bitwise complement ('Data.Bits.complement') so that @idx2 = 0@ maps to @-1@,
-- @idx2 = 1@ maps to @-2@, etc., ensuring strict negativity while keeping bit 62 zero.
{-# INLINE encodeRightSlot3 #-}
encodeRightSlot3 :: Int -> Int64
encodeRightSlot3 !idx2 =
  complement (fromIntegral idx2) .&. complement collisionBit3

-- | Encode a colliding pair of slot indices @(idx1, idx2)@ for 'OpCombineDeep'.
--
-- Packs @idx1@ into bits 30..59 and @idx2@ into bits 0..29, sets bit 62, and negates.
{-# INLINE encodeCollision3 #-}
encodeCollision3 :: Int -> Int -> Int64
encodeCollision3 !idx1 !idx2 =
  let !payload = (fromIntegral idx1 `shiftL` 30) .|. fromIntegral idx2
  in complement payload .|. collisionBit3

-- | Decode a 'MergeMorph3' gather code into its constituent source slots:
--
--   * @Left (Left idx1)@   : Unambiguous value from slot @idx1@ of the left record.
--   * @Left (Right idx2)@  : Unambiguous value from slot @idx2@ of the right record.
--   * @Right (idx1, idx2)@ : Recursive collision between @idx1@ and @idx2@.
{-# INLINE decodeMergeCode3 #-}
decodeMergeCode3 :: Int64 -> Either (Either Int Int) (Int, Int)
decodeMergeCode3 !code
  | code >= 0 = Left (Left (fromIntegral code))
  | (code .&. collisionBit3) == 0 =
      Left (Right (fromIntegral (complement code)))
  | otherwise =
      let !raw  = complement (code .&. complement collisionBit3)
          !idx1 = fromIntegral (raw `shiftR` 30)
          !idx2 = fromIntegral (raw .&. 0x3FFFFFFF)
      in Right (idx1, idx2)

-- | Branch-minimized binary search over a sorted 'PrimArray' of 'Word32' field IDs.
--
-- Returns the slot index of the target 'FieldId' if present, or 'Nothing'.
-- Operates in $O(\log N)$ time with zero heap allocations.
{-# INLINE findFieldSlot #-}
findFieldSlot :: PrimArray Word32 -> FieldId -> Maybe Int
findFieldSlot !fields (FieldId !target) =
  go 0 (sizeofPrimArray fields - 1)
  where
    go !lo !hi
      | lo > hi   = Nothing
      | otherwise =
          let !mid = (lo + hi) `unsafeShiftR` 1
              !v   = indexPrimArray fields mid
          in case compare v target of
               LT -> go (mid + 1) hi
               GT -> go lo (mid - 1)
               EQ -> Just mid

-- | Two-finger linear synthesis of a 3-way 'MergeMorph3' over two sorted schemas.
--
-- Traverses the two sorted 'PrimArray's in parallel in $O(N_1 + N_2)$ time, emitting:
--
--   1. The merged schema's sorted 'PrimArray' of field IDs.
--   2. The compiled 'MergeMorph3' gather codes for instantiating the merged record values.
synthesizeMergeMorph3
  :: RecordOp
  -> PrimArray Word32
  -> PrimArray Word32
  -> (PrimArray Word32, MergeMorph3)
synthesizeMergeMorph3 !op !f1 !f2 =
  let !n1 = sizeofPrimArray f1
      !n2 = sizeofPrimArray f2
      -- Linear merge worker with accumulators for output fields and gather codes:
      go !i !j accFields accCodes
        | i >= n1 && j >= n2 =
            -- Both inputs exhausted; finish and freeze output arrays:
            ( primArrayFromList (reverse accFields)
            , MergeMorph3 (primArrayFromList (reverse accCodes))
            )
        | i >= n1 =
            -- Left input exhausted; process remaining right-hand fields:
            case op of
              OpRestrict ->
                -- OpRestrict only retains fields present in the left record:
                ( primArrayFromList (reverse accFields)
                , MergeMorph3 (primArrayFromList (reverse accCodes))
                )
              _ ->
                let !k2 = indexPrimArray f2 j
                in go i (j + 1) (k2 : accFields) (encodeRightSlot3 j : accCodes)
        | j >= n2 =
            -- Right input exhausted; process remaining left-hand fields:
            case op of
              OpRestrict ->
                -- OpRestrict only retains fields present in both records:
                ( primArrayFromList (reverse accFields)
                , MergeMorph3 (primArrayFromList (reverse accCodes))
                )
              _ ->
                let !k1 = indexPrimArray f1 i
                in go (i + 1) j (k1 : accFields) (fromIntegral i : accCodes)
        | otherwise =
            -- Both streams have remaining elements; compare field IDs:
            let !k1 = indexPrimArray f1 i
                !k2 = indexPrimArray f2 j
            in case compare k1 k2 of
                 LT -> case op of
                   OpRestrict -> go (i + 1) j accFields accCodes
                   _          -> go (i + 1) j (k1 : accFields) (fromIntegral i : accCodes)
                 GT -> case op of
                   OpRestrict -> go i (j + 1) accFields accCodes
                   _          -> go i (j + 1) (k2 : accFields) (encodeRightSlot3 j : accCodes)
                 EQ ->
                   -- Field appears in both records; determine resolution by operation:
                   let !code = case op of
                         OpPreferR     -> encodeRightSlot3 j
                         OpCombineDeep -> encodeCollision3 i j
                         OpRestrict    -> fromIntegral i
                   in go (i + 1) (j + 1) (k1 : accFields) (code : accCodes)
  in go 0 0 [] []
