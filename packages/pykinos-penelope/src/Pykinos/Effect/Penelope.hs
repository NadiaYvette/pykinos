{-# LANGUAGE BangPatterns, DataKinds, GADTs, PolyKinds, RankNTypes, ScopedTypeVariables, PatternSynonyms #-}
{-# OPTIONS_GHC -Wno-pattern-namespace-specifier #-}

{- |
Module      : Pykinos.Effect.Penelope
Description : Penelope Higher-Order Scoped Batching, Transient Epochs, & MVCC Pushouts
Copyright   : (c) Nadia Yvette Chambers, 2026
License     : EUPL-1.2
Maintainer  : Nadia Chambers <nadia.yvette.chambers@ik.me>
Stability   : experimental
Portability : non-portable (GHC extensions, row types)

Provides Penelope effect algebra integration for transient-epoch batching, lockless
Multi-Version Concurrency Control (MVCC) snapshots, and categorical pushout merges.

= Architectural Mechanics

1. **Transient Epoch Scoping ('withTransientEpoch'):**
   In transactional workloads, serial copy-on-write allocations per individual write
   generate excessive garbage and node copies. A transient epoch amortizes allocation
   by tagging all node insertions during an active batch with a freshly minted 'EpochId'.
   Nodes created within the same epoch can be reused without defensive cloning.

2. **Lockless MVCC Snapshots ('MVCCSnapshot'):**
   Captures an \(O(1)\) reference to the root 'BPlusMap' at a given 'EpochId',
   optionally pre-materializing a contiguous 'FASTMap' read-accelerator ('msFastAcc')
   for branch-minimized query routing.

3. **Categorical Pushout Commutation ('commitEpochPushout'):**
   When two concurrent tasks fork from a common base snapshot \(V_0\) into divergent
   branches \(V_1\) and \(V_2\), their concurrent modifications form a categorical pushout span:
   \[
     \begin{array}{ccc}
       V_0 & \longrightarrow & V_1 \\
       \downarrow & & \downarrow \\
       V_2 & \longrightarrow & V_1 \amalg_{V_0} V_2
     \end{array}
   \]
   * If the disjoint deltas commute or represent idempotent updates to identical values,
     the pushout merges cleanly into a unified 'MVCCSnapshot'.
   * If concurrent writes to the same key diverge, 'commitEpochPushout' isolates the
     cellular sheaf \(H^1\) obstruction as a list of 'PushoutConflict' records.
-}
module Pykinos.Effect.Penelope
  ( -- * Higher-Order Penelope Effect
    PykinosBatchH(..)
  , PukinosBatchH
  , pattern RunPukinosBatch
    -- * MVCC Snapshots & Obstructions
  , MVCCSnapshot(..)
  , PushoutConflict(..)
    -- * Epoch Execution & Merging
  , withTransientEpoch
  , mvccSnapshot
  , commitEpochPushout
  ) where

import Data.Kind (Type)
import Pykinos.Tree.BPlus
  ( EpochId
  , BPlusMap(..)
  , lookupBPlus
  , insertBPlusEpoch
  , toAscListBPlus
  )
import Pykinos.Tree.FAST (FASTMap, freezeFAST)

-- | Higher-Order Scoped Penelope Effect for transient epoch-stamped mutations over a 'BPlusMap'.
--
-- Regions track input and output effect rows during scoped batch mutation.
data PykinosBatchH k v (regions :: [([Type], [Type])]) (ins :: [Type]) (outs :: [Type]) where
  -- | Opens a transient mutation scope with a freshly minted 'EpochId',
  --   avoiding wide-node write amplification before freezing on region exit.
  RunPykinosBatch
    :: !(BPlusMap k v)
    -> (EpochId -> BPlusMap k v -> BPlusMap k v)
    -> PykinosBatchH k v '[ '(ins, outs) ] ins outs

-- | Backward-compatible type alias for legacy PukinosBatchH.
type PukinosBatchH = PykinosBatchH

-- | Backward-compatible pattern synonym for 'RunPykinosBatch'.
pattern RunPukinosBatch
  :: forall k v (ins :: [Type]) (outs :: [Type]).
     BPlusMap k v
  -> (EpochId -> BPlusMap k v -> BPlusMap k v)
  -> PykinosBatchH k v '[ '(ins, outs) ] ins outs
pattern RunPukinosBatch m f = RunPykinosBatch m f

-- | Lockless \(O(1)\) Multi-Version Concurrency Control (MVCC) snapshot handle.
--
-- Pairs an immutable 'EpochId' watermark with the root 'BPlusMap' and an optional
-- pre-materialized 'FASTMap' read accelerator.
data MVCCSnapshot k v = MVCCSnapshot
  { msEpoch   :: {-# UNPACK #-} !EpochId
    -- ^ Epoch watermark associated with this snapshot.
  , msTree    :: !(BPlusMap k v)
    -- ^ Root persistent B+ tree node hierarchy.
  , msFastAcc :: !(Maybe (FASTMap k v))
    -- ^ Optional cache-line blocked Eytzinger read accelerator.
  } deriving (Eq, Show)

-- | Cohomological \(H^1\) merge obstruction on key 'k'.
--
-- Materialized when two concurrent branches modify the same key to conflicting,
-- non-equal values relative to base snapshot \(V_0\).
data PushoutConflict k v = PushoutConflict
  { pcKey       :: !k
    -- ^ Key where concurrent conflicting writes occurred.
  , pcBaseVal   :: !(Maybe v)
    -- ^ Original value in common ancestor snapshot \(V_0\) (if present).
  , pcLeftVal   :: !v
    -- ^ Mutated value in worker branch \(V_1\).
  , pcRightVal  :: !v
    -- ^ Divergent mutated value in worker branch \(V_2\).
  } deriving (Eq, Show)

-- | Execute a batch of modifications under a freshly incremented transient 'EpochId'.
--
-- Running time: \(O(k \log_M n)\) for \(k\) inserted entries.
{-# INLINE withTransientEpoch #-}
withTransientEpoch
  :: Ord k
  => EpochId
  -- ^ Previous epoch watermark.
  -> BPlusMap k v
  -- ^ Base B+ tree before batch modification.
  -> (EpochId -> (k -> v -> BPlusMap k v -> BPlusMap k v) -> BPlusMap k v -> BPlusMap k v)
  -- ^ Scoped mutation lambda receiving new 'EpochId' and insertion closure.
  -> (EpochId, BPlusMap k v)
withTransientEpoch !prevEpoch !baseTree batchFn =
  let !nextEpoch = prevEpoch + 1
      !resTree   = batchFn nextEpoch (insertBPlusEpoch nextEpoch) baseTree
  in (nextEpoch, resTree)

-- | Capture an \(O(1)\) lockless MVCC snapshot of a 'BPlusMap' (optionally freezing a 'FASTMap').
--
-- Running time: \(O(1)\) when @buildFast = False@; \(O(n)\) when building FAST accelerator.
{-# INLINE mvccSnapshot #-}
mvccSnapshot :: EpochId -> Bool -> BPlusMap k v -> MVCCSnapshot k v
mvccSnapshot !ep !buildFast !tree =
  MVCCSnapshot
    { msEpoch   = ep
    , msTree    = tree
    , msFastAcc = if buildFast then Just (freezeFAST tree) else Nothing
    }

-- | Compute the Categorical Pushout (\(V_1 \amalg_{V_0} V_2\)) of two concurrent 'BPlusMap'
-- branches forked from a common ancestor snapshot \(V_0\).
--
-- * If all modifications commute or resolve idempotently, returns 'Right' with the merged snapshot.
-- * If overlapping keys diverge, returns 'Left' containing the list of 'PushoutConflict' records.
--
-- Running time: \(O(|\Delta_1| \log n + |\Delta_2| \log n)\).
commitEpochPushout
  :: (Ord k, Eq v)
  => MVCCSnapshot k v
  -- ^ Base snapshot \(V_0\)
  -> BPlusMap k v
  -- ^ Worker 1 branch \(V_1\)
  -> BPlusMap k v
  -- ^ Worker 2 branch \(V_2\)
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

-- | Extract all entries in 'vBranch' that differ from base map 'v0'.
diffAgainstBase :: (Ord k, Eq v) => BPlusMap k v -> BPlusMap k v -> [(k, v)]
diffAgainstBase !v0 !vBranch =
  [ (k, v)
  | (k, v) <- toAscListBPlus vBranch
  , lookupBPlus k v0 /= Just v
  ]

-- | Sequentially apply a list of key-value deltas stamped with epoch 'ep'.
applyDeltas :: Ord k => EpochId -> BPlusMap k v -> [(k, v)] -> BPlusMap k v
applyDeltas !ep = foldl' (\acc (k, v) -> insertBPlusEpoch ep k v acc)
