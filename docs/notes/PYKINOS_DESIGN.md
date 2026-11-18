# Pykinos Architectural Design Monograph

**Status:** ARCHITECTURAL DESIGN NOTE · October/November 2026  
**Component:** `pykinos` (`pykinos-core`, `pykinos-penelope`)  
**Maintainer:** Nadia Yvette Chambers <nadia.yvette.chambers@ik.me>  
**Index:** [`../INDEX.md`](../INDEX.md)

---

## 1. Executive Summary & Purpose

`pykinos` (Epic Greek **πυκινός** *pykinos*, Attic **πυκνός** *pyknos*: *close, compact, dense, solid, shrewd, terse*, cf. Liddell & Scott, *A Greek-English Lexicon*, 1940) embodies the architectural virtue of **τὸ πυκνόν** (*to pyknon*, "terseness and compactness", Dionysius of Halicarnassus, *De Thucydide* 24; *πυκινὸς θώρηξ* "close-jointed corselet", *Iliad* 15.529). In stark contrast to sparse, pointer-chasing structures (*ἀραιός*), `pykinos` provides cache-conscious, unboxed, blocked data structures for high-performance algebraic evaluation, AST indexing, and transactional memory in the Nadiverse suite:

1. **Roaring Bitsets (`Pykinos.Bitset.Roaring`):** Two-tier compressed bitsets partitioned into 64 KiB chunks (`ArrayChunk` for sparse clusters $\le 4096$ items, `BitmapChunk` for dense bitmasks).
2. **Adaptive Radix Trees (`Pykinos.IntMap.ART`):** Cache-conscious 4-tier radix tree (`Node4`, `Node16`, `Node48`, `Node256`) optimizing key traversal depth and memory occupancy without boxed pointer chains.
3. **B+ Trees (`Pykinos.Tree.BPlus`):** Multi-way balanced branching search trees with unboxed key/value leaf nodes for ordered traversal and range slicing.
4. **FAST Accelerators (`Pykinos.Tree.FAST`):** Fast Architecture Sensitive Tree accelerators with flat unboxed sequential layouts for SIMD and cacheline prefetching.
5. **Penelope Transient Epochs & MVCC (`Pykinos.Effect.Penelope`):** Penelope effect integration providing transient epoch isolation (`withTransientEpoch`) and commutative categorical pushout merges (`pushoutMergeMVCC`) over divergent transaction branches.

---

## 2. Package Architecture

```
pykinos/
├── packages/
│   ├── pykinos-core/
│   │   ├── src/Pykinos/
│   │   │   ├── Bitset/Roaring.hs
│   │   │   ├── IntMap/ART.hs
│   │   │   ├── Tree/BPlus.hs
│   │   │   └── Tree/FAST.hs
│   │   └── test/Spec.hs
│   └── pykinos-penelope/
│       ├── src/Pykinos/
│       │   └── Effect/Penelope.hs
│       └── test/Spec.hs
```

---

## 3. Design Invariants

- **D1 (Unboxed Primitive Storage):** Containers utilize `PrimArray` and `SmallArray` from `primitive` to eliminate object header overhead and pointer indirection.
- **D2 (Transient Epoch Isolation):** Mutating operations within an epoch avoid persistent allocation until an epoch boundary snapshot is materialized.
- **D3 (Commutative Pushout Merges):** Disjoint and idempotent branches commute cleanly under categorical pushout rules in `pushoutMergeMVCC`.
- **D4 (Zero-Hint Cleanliness):** Zero HLint hints enforced across all packages under `.hlint.yaml`.
