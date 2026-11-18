# pykinos Newbie Quickstart & Token-Conservation Guide

**Parent Strategy:** [`notes/DOC_STRATEGY.md`](notes/DOC_STRATEGY.md)  
**Corpus Inventory:** [`INDEX.md`](INDEX.md)  
**Philological Exegesis:** [`notes/ETYMOLOGY.md`](notes/ETYMOLOGY.md)  
**Tutorial:** [`TUTORIAL.md`](TUTORIAL.md)  
**Design Monograph:** [`notes/PYKINOS_DESIGN.md`](notes/PYKINOS_DESIGN.md)  
**Maintainer Guide:** [`MAINTAINER_GUIDE.md`](MAINTAINER_GUIDE.md)  

---

## 1. The Core Mental Model: Unboxed Memory vs. Boxed Pointers

In conventional Haskell programming, every data constructor wraps fields in boxed pointer envelopes:
- A `data List a = Nil | Cons a (List a)` allocates an object header and two pointers per element.
- Even unboxed values like `Int` inside a standard list are boxed as `I# Int#`.

`pykinos` breaks this model by working directly with **unboxed contiguous memory** via GHC primitive arrays:
- **`ByteArray#`:** Flat unboxed memory buffer. Holds raw bytes, integers, or floating point words with zero pointer overhead.
- **`SmallArray#`:** Compact pointer arrays that omit card-marking tables, ideal for small structures ($\le 32$ elements) that fit within CPU cache lines.

```
       Boxed Haskell Structure                   Unboxed Pykinos Buffer
       +-------------+                           +-------------------------------+
       | Object Info |                           | Chunk Length | Prim Data ...  |
       |  Pointer 1  | ──> [Payload 1]           |  [ Word64, Word64, Word64 ]   |
       |  Pointer 2  | ──> [Payload 2]           +-------------------------------+
       +-------------+                                 (Contiguous flat buffer)
     (Multiple Allocations)
```

---

## 2. Progressive Disclosure Funnel: Navigating the Codebase

To explore `pykinos` efficiently without flooding the LLM context or wasting prompt tokens, follow the four-stage progressive disclosure funnel:

```
[Level 0: Global Orientation] --> docs/INDEX.md, README.md, ETYMOLOGY.md
             │
             ▼
[Level 1: Package Inventory]  --> packages/pykinos-core, packages/pykinos-penelope
             │
             ▼
[Level 2: Module Interfaces]  --> Exposed signatures in Pykinos.Bitset, Pykinos.IntMap
             │
             ▼
[Level 3: Primitive Internals]--> Primitive ByteArray# and SmallArray# array operations
```

1. **Level 0 (Global Orientation):** Read [`README.md`](../README.md) and [`docs/notes/ETYMOLOGY.md`](notes/ETYMOLOGY.md) to grasp the core philosophy of *τὸ πυκνόν* and cache contiguity.
2. **Level 1 (Package Inventory):**
   - Pure blocked containers $\rightarrow$ `pykinos-core`
   - Transactional epochs & MVCC $\rightarrow$ `pykinos-penelope`
3. **Level 2 (Module Interfaces):** Check exposed exports and type definitions in Haddock or module headers.
4. **Level 3 (Primitive Internals):** Use `ast-grep` or surgical grep slices when inspecting `PrimArray` and bit manipulation primitives.

---

## 3. The Subsystems at a Glance

| Subsystem | Module | Primary Invariant |
| :--- | :--- | :--- |
| **Roaring Bitsets** | `Pykinos.Bitset.Roaring` | Two-tier 16-bit key chunks; auto-morphs between `ArrayChunk` and `BitmapChunk` at 4,096 items. |
| **Adaptive Radix Tree** | `Pykinos.IntMap.ART` | 4 node tiers (`Node4`, `Node16`, `Node48`, `Node256`) minimizing pointer traversal depth. |
| **B+ Trees** | `Pykinos.Tree.BPlus` | Multi-way balanced search trees with unboxed contiguous leaf slots. |
| **FAST Accelerators** | `Pykinos.Tree.FAST` | Flat sequential layout for SIMD vector comparisons and prefetching. |
| **Transient Epochs** | `Pykinos.Effect.Penelope` | Local in-place mutations committed atomically at epoch boundaries. |

---

## 4. Common Gotchas

1. **Alignment & Word Boundaries:**
   - Unboxed operations on `ByteArray#` must respect word alignment (8-byte boundaries on 64-bit systems) to prevent unaligned memory access penalties.
2. **Bounds Checking:**
   - Always ensure slice indices and chunk offsets remain strictly bounded within allocated capacity before issuing index operations.
3. **Verification Compliance:**
   - Always verify your modifications with `./bin/pykinos-verify`. All five gates (HLint, Cabal tests, Tagref, Linkcheck, and CLOC) must pass with zero errors.
