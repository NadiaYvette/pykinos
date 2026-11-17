-- VERBATIM_CODE_SEED: TP-PUK-001C
-- TARGET_REPO: ~/src/pukinos
-- TARGET_PACKAGE: pukinos-penelope
-- TARGET_FILES:
--   src/Pukinos/Effect/Penelope.hs

{-# LANGUAGE BangPatterns, DataKinds, GADTs, KindSignatures, PolyKinds, RankNTypes, ScopedTypeVariables, PatternSynonyms #-}

module Pykinos.Effect.Penelope
  ( PykinosBatchH(..)
  , PukinosBatchH
  , pattern RunPukinosBatch
  , MVCCSnapshot(..)
  , PushoutConflict(..)
  , withTransientEpoch
  , mvccSnapshot
  , commitEpochPushout
  ) where

import Data.Word (Word64)
import Pykinos.Tree.BPlus
  ( EpochId
  , BPlusMap(..)
  , lookupBPlus
  , insertBPlusEpoch
  , toAscListBPlus
  )
import Pykinos.Tree.FAST (FASTMap, freezeFAST)

-- | Higher-Order Scoped Penelope Effect ('OpH #PykinosBatch') for transient
--   epoch-stamped mutations over a 'BPlusMap k v'.
data PykinosBatchH k v (regions :: [([*], [*])]) (ins :: [*]) (outs :: [*]) where
  -- | Opens a transient mutation scope with a freshly minted 'EpochId',
  --   avoiding wide-node write amplification before freezing on region exit.
  RunPykinosBatch
    :: !(BPlusMap k v)
    -> (EpochId -> BPlusMap k v -> BPlusMap k v)
    -> PykinosBatchH k v '[ '(ins, outs) ] ins outs

-- | Backward-compatible alias for legacy PukinosBatchH
type PukinosBatchH = PykinosBatchH

-- | Backward-compatible pattern synonym for RunPukinosBatch
pattern RunPukinosBatch
  :: forall k v (ins :: [*]) (outs :: [*]).
     BPlusMap k v
  -> (EpochId -> BPlusMap k v -> BPlusMap k v)
  -> PykinosBatchH k v '[ '(ins, outs) ] ins outs
pattern RunPukinosBatch m f = RunPykinosBatch m f

-- | Lockless O(1) Multi-Version Concurrency Control (MVCC) snapshot handle.
--   Pairs the immutable 'EpochId' watermark with the root 'BPlusMap' and
--   an optional materialized 'FASTMap' read accelerator.
data MVCCSnapshot k v = MVCCSnapshot
  { msEpoch   :: {-# UNPACK #-} !EpochId
  , msTree    :: !(BPlusMap k v)
  , msFastAcc :: !(Maybe (FASTMap k v))
  } deriving (Eq, Show)

-- | Cohomological H^1 merge obstruction on key 'k' when concurrent workers
--   mutate the same key to non-equal values relative to base snapshot 'V_0'.
data PushoutConflict k v = PushoutConflict
  { pcKey       :: !k
  , pcBaseVal   :: !(Maybe v)
  , pcLeftVal   :: !v
  , pcRightVal  :: !v
  } deriving (Eq, Show)

-- | Execute a batch of modifications under a fresh transient 'EpochId'.
{-# INLINE withTransientEpoch #-}
withTransientEpoch
  :: Ord k
  => EpochId
  -> BPlusMap k v
  -> (EpochId -> (k -> v -> BPlusMap k v -> BPlusMap k v) -> BPlusMap k v -> BPlusMap k v)
  -> (EpochId, BPlusMap k v)
withTransientEpoch !prevEpoch !baseTree batchFn =
  let !nextEpoch = prevEpoch + 1
      !resTree   = batchFn nextEpoch (insertBPlusEpoch nextEpoch) baseTree
  in (nextEpoch, resTree)

-- | Take an O(1) lockless MVCC snapshot of a 'BPlusMap' (optionally building the FAST index).
{-# INLINE mvccSnapshot #-}
mvccSnapshot :: Ord k => EpochId -> Bool -> BPlusMap k v -> MVCCSnapshot k v
mvccSnapshot !ep !buildFast !tree =
  MVCCSnapshot
    { msEpoch   = ep
    , msTree    = tree
    , msFastAcc = if buildFast then Just (freezeFAST tree) else Nothing
    }

-- | Compute the Categorical Pushout (V_1 ⨿_{V_0} V_2) of two concurrent 'BPlusMap'
--   workspaces forked from a common base snapshot 'V_0'.
--   * If all mutations commute, returns 'Right (MVCCSnapshot newEpoch mergedTree)'.
--   * If overlapping keys diverge, returns 'Left [PushoutConflict k v]' (the H^1 obstruction).
commitEpochPushout
  :: (Ord k, Eq v)
  => MVCCSnapshot k v   -- ^ Base snapshot V_0
  -> BPlusMap k v       -- ^ Worker 1 branch V_1
  -> BPlusMap k v       -- ^ Worker 2 branch V_2
  -> Either [PushoutConflict k v] (MVCCSnapshot k v)
commitEpochPushout (MVCCSnapshot !baseEp !v0 _) !v1 !v2 =
  let !newEp     = baseEp + 1
      !deltas1   = diffAgainstBase v0 v1
      !deltas2   = diffAgainstBase v0 v2
      (!conflicts, !merged) =
        foldl'
          (\(!errs, !accTree) (k, val2) ->
            case lookup k deltas1 of
              Nothing ->
                (errs, insertBPlusEpoch newEp k val2 accTree)
              Just val1
                | val1 == val2 ->
                    (errs, insertBPlusEpoch newEp k val1 accTree)
                | otherwise ->
                    let !c = PushoutConflict k (lookupBPlus k v0) val1 val2
                    in (c : errs, accTree))
          ([], applyDeltas newEp v0 deltas1)
          deltas2
  in case conflicts of
       [] -> Right (mvccSnapshot newEp False merged)
       cs -> Left (reverse cs)

diffAgainstBase :: (Ord k, Eq v) => BPlusMap k v -> BPlusMap k v -> [(k, v)]
diffAgainstBase !v0 !vBranch =
  [ (k, v)
  | (k, v) <- toAscListBPlus vBranch
  , lookupBPlus k v0 /= Just v
  ]

applyDeltas :: Ord k => EpochId -> BPlusMap k v -> [(k, v)] -> BPlusMap k v
applyDeltas !ep = foldl' (\acc (k, v) -> insertBPlusEpoch ep k v acc)