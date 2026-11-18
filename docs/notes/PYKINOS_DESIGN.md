# Pykinos Architectural Design Monograph

**Status:** CANONICAL ARCHITECTURAL DESIGN NOTE · November 2026  
**Component:** `pykinos` (`pykinos-core`, `pykinos-penelope`)  
**Maintainer:** Nadia Yvette Chambers <nadia.yvette.chambers@ik.me>  
**Corpus Inventory:** [`../INDEX.md`](../INDEX.md)  
**Parent Strategy:** [`DOC_STRATEGY.md`](DOC_STRATEGY.md)  
**Philological Exegesis:** [`ETYMOLOGY.md`](ETYMOLOGY.md)  
**Tutorial Track:** [`../TUTORIAL.md`](../TUTORIAL.md)  

---

## 1. Executive Summary & Philological Heritage

`pykinos` (Epic Greek **πυκινός** *pykinos*, Attic **πυκνός** *pyknos*: *close, compact, dense, solid, shrewd, terse*, cf. Liddell & Scott, *A Greek-English Lexicon*, Clarendon Press, 1940) embodies the architectural virtue of **τὸ πυκνόν** (*to pyknon*, "terseness, compactness, and high density", Dionysius of Halicarnassus, *De Thucydide* 24).

```
   Classical Domains of τὸ πυκνόν
   ├── [Physical Density]       : Homer, Il. 15.529 (πυκινὸς θώρηξ, "close-jointed corselet")
   │                              Plato, Tim. 59b (χρυσοῦ πυκνότερον, "denser than gold")
   │                              Military tactics: en pyknō ("in close order") vs araios ("sparse")
   └── [Intellectual Shrewdness]: Homer, Il. 14.294 (πυκιναὶ φρένες, "shrewd, sound mind")
                                  Homer, Il. 3.208 (πυκινὰ μήδεα, "dense, wise counsels")
                                  Dionysius, De Thuc. 24 (τὸ πυκνόν, "density of expression")
```

### The Architectural Double Entendre

`pykinos` establishes a deliberate double entendre:
1. **Physical Compactness:** In stark opposition to sparse, pointer-chasing structures (*ἀραιός*), `pykinos` allocates data into unboxed, contiguous, cache-line-aligned primitive arrays (`ByteArray#`, `SmallArray#`), tightly packing data into cache lines (*πυκινῶς*).
2. **Intellectual Shrewdness & Terseness:** `pykinos` employs self-optimizing adaptive structures that dynamically morph their internal representations as elements are inserted or deleted (Roaring Bitsets, Adaptive Radix Trees, dynamic Hidden Classes; *πυκιναὶ φρένες*).

### The Constellation Duality: `cek` vs. `pykinos`

- **`cek` draws upon the Computer Science Literature:** Abstract reduction machines (Landin 1964, Felleisen-Friedman 1986, Danvy-Nielsen 2001, Rossberg 2018), operational continuations, and tail-recursive trampolines.
- **`pykinos` draws upon the Classical Greek Literature:** Ancient physical density, close tactical order, rhetorical compactness, and unboxed hardware contiguity.

---

## 2. Hardware Topography & The Cache Line Reality

Modern CPU execution engines operate at multi-gigahertz frequencies, capable of issuing multiple instructions per clock cycle. However, main memory (DRAM) access latencies remain high (50–100 nanoseconds, or 150–250 CPU cycles):

| Memory Level | Typical Size | Typical Latency (Cycles) |
| :--- | :--- | :--- |
| **L1 Data Cache** | 32–64 KiB | ~4 cycles |
| **L2 Data Cache** | 512 KiB – 1 MiB | ~12–14 cycles |
| **L3 Shared Cache** | 16–64 MiB | ~40–60 cycles |
| **Main Memory (DRAM)** | 16–128 GiB | ~150–250 cycles |

When a program traverses standard functional data structures (e.g. `Data.Map` or `Data.Set`):
- Every node is a heap object with an 8-byte info pointer and constructor payload.
- Pointers scatter objects across the heap (*ἀραιός*).
- Traversing a tree of depth $D$ triggers up to $D$ separate cache misses, causing CPU execution pipelines to stall waiting for memory controllers.

`pykinos` eliminates this latency wall by aligning nodes with 64-byte hardware cache lines, packing multiple keys and child references into unboxed slices that fill an entire cache line in a single memory fetch.

---

## 3. Two-Tier Roaring Bitsets (`Pykinos.Bitset.Roaring`)

Roaring bitsets partition a 32-bit integer space into $2^{16}$ chunks based on the most significant 16 bits of each key. Each chunk holds integers sharing the same high 16 bits:

```
  Integer Key (32-bit): [ High 16 bits (Chunk Key) | Low 16 bits (Offset) ]
                                   │
                                   ▼
          +───────────────────────────────────────────────────+
          |           Roaring Top-Level Directory             |
          +───────────────────────────────────────────────────+
             │                                     │
             ▼                                     ▼
  +─────────────────────+               +─────────────────────+
  |     ArrayChunk      |               |     BitmapChunk     |
  |  (Cardinality <= 4k)|               |  (Cardinality > 4k) |
  |  Sorted Word16[]    |               |  1024 x Word64      |
  +─────────────────────+               +─────────────────────+
```

### Transition Mechanics

- **`ArrayChunk`:** When a chunk contains $\le 4,096$ integers, storing a full 8 KiB bitmask would waste memory. Instead, it stores elements as a sorted unboxed array of 16-bit integers (`PrimArray Word16`). Queries execute via binary search in $O(\log N)$ time.
- **`BitmapChunk`:** Once cardinality exceeds 4,096 elements, the chunk automatically morphs into a flat bitmask of 1,024 64-bit words (exactly 8 KiB, representing 65,536 bits). Membership lookup becomes an $O(1)$ bitwise operation:
  \[
    \text{wordIdx} = \text{offset} \gg 6, \quad \text{bitIdx} = \text{offset} \ \& \ 63
  \]
- **Density Invariant:** Converting between `ArrayChunk` and `BitmapChunk` is completely transparent, maintaining optimal memory density across both sparse and dense workloads.

---

## 4. Adaptive Radix Trees (`Pykinos.IntMap.ART`)

The Adaptive Radix Tree (Leis et al., 2013) combines the height-bounded search efficiency of tries with the space efficiency of multi-way search trees. ART adapts the size of internal nodes dynamically across four tiers:

1. **`Node4` (2 to 4 children):**
   - Contains an unboxed array of 4 key bytes and 4 child pointers.
   - Total node size fits inside a single 64-byte CPU cache line.
2. **`Node16` (5 to 16 children):**
   - Contains 16 key bytes and 16 child pointers.
   - Keys are compared in parallel using 128-bit SIMD vector instructions (e.g. `_mm_cmpeq_epi8`), locating the target branch in $O(1)$ without sequential loops.
3. **`Node48` (17 to 48 children):**
   - Uses a 256-byte index array mapping byte keys directly to 48 child pointer slots.
4. **`Node256` (49 to 256 children):**
   - A direct 256-entry array of child pointers for maximum branch factor.

---

## 5. B+ Trees and FAST Prefetching Layouts

- **`Pykinos.Tree.BPlus`:** Multi-way balanced branching trees with unboxed key/value leaf nodes. Sequential range scans stream through leaf blocks without visiting interior parent nodes.
- **`Pykinos.Tree.FAST`:** Fast Architecture Sensitive Trees map the entire tree hierarchy into flat, sequential unboxed memory buffers, enabling hardware prefetchers to load successive tree levels before instructions are issued.

---

## 6. Transient Epoch Isolation & Pushout MVCC

`pykinos-penelope` introduces transactional execution for high-frequency operations:

1. **Transient Epochs (`withTransientEpoch`):**
   - Allocates an ephemeral scratchpad region for local mutations.
   - Reclaims scratch memory in bulk upon epoch completion, minimizing GC heap churn.
2. **Pushout Categorical Merges (`pushoutMergeMVCC`):**
   - Implements multi-version concurrency control (MVCC) without global mutex locks.
   - Given a common ancestor $C$ and divergent branches $A \xleftarrow{f} C \xrightarrow{g} B$, `pushoutMergeMVCC` computes the pushout $A \sqcup_C B$:
     \[
       \begin{CD}
         C @>g>> B \\
         @V f VV @VV g' V \\
         A @>>f'> A \sqcup_C B
       \end{CD}
     \]
   - Disjoint key modifications commute automatically, guaranteeing deterministic conflict resolution.

---

## 7. Design Invariants & Formal Guarantees

- **D1 (Unboxed Memory Invariant):** All leaf payloads and key arrays in `pykinos-core` utilize unboxed primitive arrays (`ByteArray#`, `PrimArray`), eliminating object headers.
- **D2 (Cache-Line Alignment):** Small internal nodes (`Node4`, `Node16`) are bounded by 64 bytes to guarantee single-fetch cache line residency.
- **D3 (Deterministic Morphing):** Chunk and node conversions between representations are total, idempotent, and reversible.
- **D4 (PVP & Hackage Compliance):** All packages maintain 0 errors/warnings under `cabal check` and pass all 5 gates in `./bin/pykinos-verify`.

---

## 8. Selected References

1. **Liddell, H. G., & Scott, R. (1940).** *A Greek-English Lexicon.* Revised by Sir Henry Stuart Jones with Roderick McKenzie. Clarendon Press, Oxford. Entries: πυκνός, πυκινός, τὸ πυκνόν.
2. **Leis, V., Kemper, A., & Neumann, T. (2013).** *The Adaptive Radix Tree: ARTful Indexing for Main-Memory Databases.* In IEEE 29th International Conference on Data Engineering (ICDE) (pp. 38-49).
3. **Chambre, D., Lemire, D., Kaser, O., & Godin, R. (2016).** *Consistently Faster and Smaller Compressed Bitmaps with Roaring.* Software: Practice and Experience, 46(5), 667-695.
4. **Kim, C., Chhugani, J., Satish, N., et al. (2010).** *FAST: Fast Architecture Sensitive Tree Search on Modern CPUs and GPUs.* In ACM SIGMOD International Conference on Management of Data (pp. 339-350).
5. **Dionysius of Halicarnassus (1st c. BCE).** *De Thucydide (On Thucydides)*, Chapter 24 (Defining τὸ πυκνόν as stylistic compactness and conceptual density).
