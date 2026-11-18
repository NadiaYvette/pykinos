# pykinos-core — Unboxed Blocked Memory Substrates

> **πυκινός** (*pykinos*, Epic Greek; Attic **πυκνός** *pyknos*): *close, compact, dense, solid, shrewd, terse*.  
> Named after the Homeric *πυκινὸς θώρηξ* (*Iliad* 15.529, "a close-fitting corselet") and *πυκιναὶ φάλαγγες* (*Iliad* 4.281, "dense close-packed phalanxes"), in opposition to *ἀραιός* ("sparse, dispersed").

`pykinos-core` provides high-performance, cache-conscious, unboxed data structures engineered to minimize pointer indirection, eliminate object header overhead, and maximize CPU cache line density in Haskell:

1. **Roaring Bitsets (`Pykinos.Bitset.Roaring`):** Unboxed two-tier compressed bitsets partitioned into 64 KiB chunks (`ArrayChunk` for sparse clusters $\le 4096$, `BitmapChunk` for dense bitmasks).
2. **Adaptive Radix Trees (`Pykinos.IntMap.ART`):** Cache-conscious 4-tier radix tree (`Node4`, `Node16`, `Node48`, `Node256`) that adapts node sizing to branch density, slashing pointer chasing.
3. **B+ Trees (`Pykinos.Tree.BPlus`):** Multi-way balanced search trees with unboxed key/value leaf nodes for ordered traversal and range slicing.
4. **FAST Accelerators (`Pykinos.Tree.FAST`):** Fast Architecture Sensitive Tree accelerators with sequential layouts tailored for SIMD and hardware prefetchers.
5. **Swiss Tables (`Pykinos.Mutable.SwissTable`):** High-speed open-addressing hash table with 1-byte control words and SSE/AVX metadata scanning.
6. **Hidden Classes (`Pykinos.Schema.HiddenClass`):** Self-optimizing schema transitions and interning for dynamic and extensible record representations.

## License

EUPL-1.2.
