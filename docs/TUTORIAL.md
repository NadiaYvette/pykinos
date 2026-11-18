# Getting Started with pykinos: A Guide to Cache-Conscious Data Structures

**Parent Strategy:** [`notes/DOC_STRATEGY.md`](notes/DOC_STRATEGY.md)  
**Corpus Inventory:** [`INDEX.md`](INDEX.md)  
**Philological Exegesis:** [`notes/ETYMOLOGY.md`](notes/ETYMOLOGY.md)  
**Design Monograph:** [`notes/PYKINOS_DESIGN.md`](notes/PYKINOS_DESIGN.md)  
**Maintainer Guide:** [`MAINTAINER_GUIDE.md`](MAINTAINER_GUIDE.md)  
**Newbie Orientation:** [`NEWBIE_GUIDE.md`](NEWBIE_GUIDE.md)  

---

## 1. The Core Philosophy: *Τὸ Πυκνόν* vs. *Ἀραιός*

In modern hardware architectures, the primary performance bottleneck is memory latency, not arithmetic throughput. A CPU cache miss to main memory incurs a latency of 150–250 CPU cycles.

Standard functional programming representations in Haskell rely on boxed algebraic data types:
- Every data constructor introduces a heap object with an info table pointer (8 bytes) and constructor fields.
- Traversing a binary tree (like `Data.Map` or `Data.Set`) or a linked list forces the CPU into pointer chasing across fragmented heap memory (*ἀραιός*, sparse and dispersed).
- Each pointer dereference risks an L1/L2/L3 cache miss and leaves cache line bytes unused.

`pykinos` adheres to the ancient Greek virtue of **τὸ πυκνόν** (*to pyknon*, "terseness, compactness, and high density"):

```
      Sparse Pointer Chasing (ἀραιός)                 Dense Blocked Contiguity (πυκινός)
   +------+       +------+       +------+          +--------------------------------------+
   | Node | ----> | Node | ----> | Node |          | Chunk: 64-byte Cache-Line Aligned    |
   | Info |       | Info |       | Info |          | [k0, k1, k2, k3 | v0, v1, v2, v3]    |
   +------+       +------+       +------+          +--------------------------------------+
   (Every jump = Potential Cache Miss)             (Single memory fetch fills CPU L1 cache)
```

This reflects an intentional **double entendre**:
1. **Physical Compactness:** Storing keys and values in unboxed, contiguous, cache-line-aligned memory blocks (`ByteArray#`, `SmallArray#`) where items are packed firmly together (*πυκινῶς*).
2. **Intellectual Shrewdness & Terseness:** Employing adaptive data representations that self-optimize based on density (Roaring Bitsets, Adaptive Radix Trees, and dynamic Hidden Classes; *πυκιναὶ φρένες*).

While `cek` embodies the **computer science literature** of abstract machines, `pykinos` embodies the **classical Greek literature** of material density and intellectual sharpness.

---

## 2. Installation & Quickstart

The `pykinos` repository contains two tightly integrated packages:

| Package | Purpose | Category |
| :--- | :--- | :--- |
| **`pykinos-core`** | Roaring Bitsets, Adaptive Radix Trees (ART), B+ Trees, and FAST accelerators | Blocked Containers |
| **`pykinos-penelope`** | Transient epoch isolation and lockless categorical MVCC pushout merges | Transactional Subsystem |

To build both packages and run tests:

```bash
cd ~/src/pykinos

# Build both packages
cabal build all

# Run test suites
cabal test all

# Run the 5 physical verification gates
./bin/pykinos-verify
```

---

## 3. High-Density Indexing with Roaring Bitsets (`Pykinos.Bitset.Roaring`)

Roaring bitsets partition 32-bit unsigned integer key spaces into 16-bit chunks. Each chunk represents a container for up to 65,536 integers ($2^{16}$):

- **`ArrayChunk` (Sparse):** When a chunk holds $\le 4,096$ integers, it is represented as a sorted, unboxed array of 16-bit words (`Word16`). Binary search locates items in $O(\log N)$ with zero object header overhead.
- **`BitmapChunk` (Dense):** When a chunk holds $> 4,096$ integers, it automatically morphs into a flat bitmask of 1,024 64-bit words (8 KiB). Testing a bit is an $O(1)$ bit shift and mask (`testBit`).

### Worked Example: Set Operations

```haskell
import Pykinos.Bitset.Roaring as Roaring

-- Initialize an empty roaring bitset:
let s0 = Roaring.empty

-- Insert integers across sparse and dense ranges:
let s1 = Roaring.insert 100 s0
let s2 = Roaring.insert 105 s1
let s3 = Roaring.insert 70000 s2  -- Placed in chunk 1 (65536..131071)

-- Fast membership testing:
print (Roaring.member 100 s3)     -- True
print (Roaring.member 101 s3)     -- False

-- Set algebra with SIMD-friendly bitwise operations:
let odds  = Roaring.fromList [1, 3, 5, 7, 9]
let evens = Roaring.fromList [2, 4, 6, 8, 10]
let unionSet = Roaring.union odds evens
```

---

## 4. Adaptive Radix Trees (`Pykinos.IntMap.ART`)

Standard trie or radix trees suffer from excessive node overhead when branches are sparsely populated. The **Adaptive Radix Tree (ART)** dynamically morphs its internal node layouts across four distinct tiers:

```
  Node4 (2..4 children)   ──>   Node16 (5..16 children)
            │                               │
            ▼                               ▼
  Node48 (17..48 children)──>   Node256 (49..256 children)
```

1. **`Node4`:** Stores up to 4 keys and 4 child pointers in compact unboxed arrays. Fits within a single 64-byte cache line.
2. **`Node16`:** Stores up to 16 keys and 16 child pointers. Keys can be searched in parallel using SIMD-width comparison vectors.
3. **`Node48`:** Uses a 256-byte index array mapping byte keys to 48 child slots.
4. **`Node256`:** Full 256-slot pointer array for direct $O(1)$ child indexing.

### Worked Example: Key-Value Mapping

```haskell
import Pykinos.IntMap.ART as ART

-- Create an empty adaptive radix tree:
let t0 = ART.empty

-- Insert key-value pairs:
let t1 = ART.insert 42 "answer" t0
let t2 = ART.insert 1337 "leet" t1

-- Lookup with minimal cache line traversal:
print (ART.lookup 42 t2)    -- Just "answer"
print (ART.lookup 99 t2)    -- Nothing
```

---

## 5. B+ Trees and FAST Accelerators

For ordered key ranges and cacheline prefetching:
- **`Pykinos.Tree.BPlus`:** Balanced multi-way search trees with unboxed keys and values in leaf pages. Range queries (`rangeSlice minKey maxKey`) stream directly from contiguous memory.
- **`Pykinos.Tree.FAST`:** Fast Architecture Sensitive Trees layout the complete tree into flat unboxed sequential memory arrays, allowing hardware prefetchers to anticipate navigation paths without pointer hops.

---

## 6. Transient Epoch Isolation & Lockless MVCC (`pykinos-penelope`)

`pykinos-penelope` integrates the blocked data structures with Penelope's algebraic effect system, providing transactional execution:

### 1. Transient Epochs (`withTransientEpoch`)
Allows high-throughput mutable updates inside an isolated epoch buffer. Allocations inside the epoch remain strictly local; persistent nodes are only instantiated when the epoch commits.

### 2. Lockless MVCC Pushout Merges (`pushoutMergeMVCC`)
When concurrent transactions fork divergent branches of a map or schema:
\[
  \text{Branch } A \longleftarrow \text{Base} \longrightarrow \text{Branch } B
\]
`pushoutMergeMVCC` computes the categorical **pushout** over the shared ancestor, resolving non-conflicting disjoint key updates commutatively without global locking.

---

## 7. Next Steps

- Explore the historical and lexicographical background in [`docs/notes/ETYMOLOGY.md`](notes/ETYMOLOGY.md).
- Study the detailed formal invariants in [`docs/notes/PYKINOS_DESIGN.md`](notes/PYKINOS_DESIGN.md).
- Follow the token-conservation funnel in [`docs/NEWBIE_GUIDE.md`](NEWBIE_GUIDE.md).
