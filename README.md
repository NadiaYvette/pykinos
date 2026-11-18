# pykinos — πυκινός

> **πυκινός** (*pykinos*, Epic Greek; Attic **πυκνός** *pyknos*): *close, compact, dense, solid, shrewd, terse*.
>
> — *πυκινὸς θώρηξ* (Homer, *Iliad* 15.529): "a close-jointed, firmly-fashioned corselet."  
> — *πυκιναὶ κίνυντο φάλαγγες* (Homer, *Iliad* 4.281): "the dense, close-packed phalanxes surged forward" (in ancient tactics, *en pyknō* "close order", opposed to *araios* "sparse, dispersed").  
> — *χρυσοῦ πυκνότερον* (Plato, *Timaeus* 59b): "denser than gold."  
> — *πυκιναὶ φρένες* (Homer, *Iliad* 14.294): "shrewd, sound, concentrated minds."  
> — *τὸ πυκνόν* (Dionysius of Halicarnassus, *De Thucydide* 24): "terseness and density of expression" — packing the greatest conceptual payload into minimal space.
>
> *(Liddell & Scott, A Greek-English Lexicon, Clarendon Press, 1940).*

In modern computing systems, CPU cache hierarchies heavily penalize sparse, pointer-chasing data structures (*ἀραιός*). Indirection chains trigger cache misses, pipeline stalls, and GC heap fragmentation.

`pykinos` adheres to the ancient virtue of **τὸ πυκνόν**: a deliberate double entendre uniting **physical compactness** (unboxed, contiguous, cache-line aligned primitive memory structures where data is packed firmly together, *πυκινῶς*) with **intellectual shrewdness and terseness** (adaptive radix morphing, lockless transient epoch MVCC, and self-optimizing hidden classes; *πυκιναὶ φρένες*). While `cek` draws upon the formal **computer science literature** of abstract reduction machines, `pykinos` draws upon the **classical Greek literature** to provide high-performance blocked memory substrates and cache-conscious execution for the Haskell ecosystem.

---

## Architecture & Subsystems

The `pykinos` workspace provides two modular packages:

1. **[`pykinos-core`](packages/pykinos-core/)**:
   - **Roaring Bitsets (`Pykinos.Bitset.Roaring`):** Two-tier compressed bitsets partitioned into 64 KiB chunks (`ArrayChunk` for sparse clusters $\le 4096$, `BitmapChunk` for dense bitmasks).
   - **Adaptive Radix Trees (`Pykinos.IntMap.ART`):** Cache-conscious 4-tier radix tree (`Node4`, `Node16`, `Node48`, `Node256`) optimizing key traversal depth without boxed pointer chains.
   - **B+ Trees (`Pykinos.Tree.BPlus`):** Multi-way balanced search trees with unboxed leaf nodes for ordered traversal and range queries.
   - **FAST Accelerators (`Pykinos.Tree.FAST`):** Fast Architecture Sensitive Tree accelerators with flat unboxed sequential layouts for SIMD and cacheline prefetching.
   - **Hidden Classes (`Pykinos.Schema.HiddenClass`):** Structural transition graphs and schema interning for dynamic and first-class records.

2. **[`pykinos-penelope`](packages/pykinos-penelope/)**:
   - **Transient Epoch Isolation (`withTransientEpoch`):** Zero-allocation transactional mutation in ephemeral memory windows.
   - **Lockless MVCC Handles (`pushoutMergeMVCC`):** Categorical pushout merges over divergent transaction branches.

---

## Quick Start

```bash
# Build all packages
cabal build all

# Run full test suite
cabal test all

# Run physical verification gates
./bin/pykinos-verify
```

## Documentation

- [`docs/notes/ETYMOLOGY.md`](docs/notes/ETYMOLOGY.md) — Comprehensive philological and lexicographical record.
- [`docs/notes/PYKINOS_DESIGN.md`](docs/notes/PYKINOS_DESIGN.md) — Architectural design monograph.
- [`AGENTS.md`](AGENTS.md) — Advisory context and rules for AI assistants.
- [`PLAN.md`](PLAN.md) — Strategic roadmap and phase delivery schedule.
- [`STATE.md`](STATE.md) — Active operational session frontier.
- [`docs/INDEX.md`](docs/INDEX.md) — Documentation corpus inventory.

## License & Attribution

- **License:** EUPL-1.2
- **Author:** Nadia Yvette Chambers <nadia.yvette.chambers@ik.me>
