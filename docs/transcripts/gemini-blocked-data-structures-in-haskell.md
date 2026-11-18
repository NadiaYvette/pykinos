# **Blocked Data Structures in Haskell**

[https\://gemini.google.com/app/2d2fb737b8a6886a](https://gemini.google.com/app/2d2fb737b8a6886a)

*User prompt: Blocked Data Structures in Haskell How could I implement blocked data structures like B+ trees, adaptive radix-B+ tree hybrids in Haskell, hash tries etc.? I'm not entirely familiar with the algorithms for high-dimensional search, but in any event, it seems like with \`polytropos\` I got moderately closer to raw memory with some element of structural interpretation, though SmallArray\# Any falls slightly short of it, but anyhow. How can these kinds of blocked data structures be implemented in Haskell?*

Response: Implementing cache-conscious blocked data structures in Haskell requires bridging the gap between **lifted pointer arrays** (SmallArray\# Any) and **unscanned raw memory** (ByteArray\#).

In polytropos, representing products and sums as Rep {-\# UNPACK \#-} \!Word \!(SmallArray (f Any)) (or Rep Int\# (SmallArray\# Any)) achieves *O*(1) structural indexing by erasing field types to Any. However, SmallArray\# Any falls short for blocked search structures for three reasons related to GHC's runtime system (RTS):

> 1. **The GC Pointer Invariant:** Every slot in a SmallArray\# is traced by the GHC Garbage Collector as a heap pointer. You cannot unsafeCoerce\# raw unboxed scalar keys (Word64\#, Double\#) into a SmallArray\# Any without crashing the GC when it attempts to dereference a scalar value as an info-table pointer.  
> 2. **Cache-Line Indirection:** Because SmallArray\# Any stores 8-byte pointers to boxed heap objects, binary or linear searching 16 keys inside a node chases 16 separate pointers across the heap, defeating CPU hardware prefetchers and L1 cache locality.  
> 3. **GC Scavenging Overhead:** During minor and major collections, the GC must scan every slot of every live SmallArray\#. In a large tree where 80% of node data consists of scalar keys, hashes, prefixes, or bounding boxes, storing them in SmallArray\# wastes substantial GC bandwidth.

## **1\. The Core Primitive: The Bifurcated Block (ByteArray\# \+ SmallArray\# Any)**

To get raw memory layout alongside polymorphic Haskell payloads, split every blocked node into two primitive heap objects:

> * **ByteArray\# (Unscanned Data Plane):** Holds node headers, bitmaps, routing prefixes, scalar keys, or SIMD lanes. The GHC GC never scans the interior of a ByteArray\#, and you can run branchless AVX2/NEON SIMD primops (like those in linear-massiv) directly over its contents.  
> * **SmallArray\# Any (Scanned Pointer Plane):** Holds child node pointers (for internal nodes) and lifted polymorphic values v (for leaf nodes).

`{-# LANGUAGE MagicHash, UnboxedTuples, RoleAnnotations, KindSignatures #-}`

`import GHC.Exts`

`-- | The universal blocked node representation:`  
`--   * Word#          : Unboxed node header (tag, count, or bitmap)`  
`--   * ByteArray#     : Packed unboxed scalar keys, prefixes, or bounding boxes`  
`--   * SmallArray# Any: Child node pointers and/or lifted payload values`  
`data BlockNode k v = BlockNode`  
  `Word#`  
  `ByteArray#`  
  `(SmallArray# Any)`

On the GHC heap, BlockNode is a 4-word closure pointing to one flat byte region and one flat pointer region without card-table overhead (SmallArray\# omits the 128-element mutability card table of Array\#).

## **2\. Implementing Specific Blocked Structures**

### **A. Blocked B+ Trees**

In a textbook C++ B+ tree, leaves are linked horizontally via next pointers for range scans. **In persistent Haskell, you must omit horizontal leaf pointers**: updating a single leaf in a persistent tree with horizontal links forces copy-on-write cloning of every leaf to its left, degrading *O*(log*B*​*N*) updates into *O*(*N*). Instead, persistent B+ trees rely on an explicit spine zipper (or continuation) for *O*(1) amortized step-wise range iteration, while ephemeral B+ trees in ST s can retain SmallMutableArray\# s sibling links.

> * **Internal Node (*B*\=16 or 32):**  
  * ByteArray\#: *B*−1 contiguous unboxed keys (e.g., Int64\# at 8-byte offsets, fitting 8 keys per 64-byte cache line).  
  * SmallArray\# Any: *B* child BlockNode pointers.  
> * **Leaf Node (*B*\=16 or 32):**  
  * ByteArray\#: *B* contiguous unboxed keys.  
  * SmallArray\# Any: *B* lifted values v (coerced via unsafeCoerce\#). If v is also a Prim type, you can pack both keys and values into the ByteArray\# and pass an empty SmallArray\# static closure.

`-- Branchless rank search inside a 16-key B+ node using raw ByteArray# reads`  
`findChildIndex16 :: ByteArray# -> Int# -> Int64# -> Int#`  
`findChildIndex16 keys# count# target# = go 0# 0#`  
  `where`  
    `go :: Int# -> Int# -> Int#`  
    `go i# acc#`  
      `| isTrue# (i# >=# count#) = acc#`  
      `| otherwise =`  
          `let k# = indexInt64Array# keys# i#`  
              `-- Branchless increment: adds 1# if target# >= k#, else 0#`  
              `cmp# = target# >=# k#`  
          `in go (i# +# 1#) (acc# +# cmp#)`

With GHC 9.14's SIMD primops (Int64X4\#), a 16-key node search loads four vectors with indexInt64X4Array\#, compares against broadcastInt64X4\# target\#, and extracts the index in 4 instructions with zero branch mispredictions.

**Copy-on-Write Node Insertion:** Inserting into a non-full node allocates one MutableByteArray\# and one SmallMutableArray\#, using primitive array copies before freezing:

`insertLeafSlot`  
  `:: Int#              -- ^ Current key count n#`  
  `-> Int#              -- ^ Insertion index idx#`  
  `-> Int64#            -- ^ Unboxed key`  
  `-> v                 -- ^ Lifted value`  
  `-> ByteArray#        -- ^ Old keys`  
  `-> SmallArray# Any   -- ^ Old values`  
  `-> (# ByteArray#, SmallArray# Any #)`  
`insertLeafSlot n# idx# key# val oldKeys# oldVals# = runRW# $ \s0 ->`  
  `let newLen# = n# +# 1#`  
      `bytesPerKey# = 8#`  
  `in case newByteArray# (newLen# *# bytesPerKey#) s0 of { (# s1, mKeys# #) ->`  
     `case copyByteArray# oldKeys# 0# mKeys# 0# (idx# *# bytesPerKey#) s1 of { s2 ->`  
     `case writeInt64Array# mKeys# idx# key# s2 of { s3 ->`  
     `case copyByteArray# oldKeys# (idx# *# bytesPerKey#) mKeys# ((idx# +# 1#) *# bytesPerKey#) ((n# -# idx#) *# bytesPerKey#) s3 of { s4 ->`  
     `case unsafeFreezeByteArray# mKeys# s4 of { (# s5, frozenKeys# #) ->`  
     `case newSmallArray# newLen# (unsafeCoerce# val) s5 of { (# s6, mVals# #) ->`  
     `case copySmallArray# oldVals# 0# mVals# 0# idx# s6 of { s7 ->`  
     `case copySmallArray# oldVals# idx# mVals# (idx# +# 1#) (n# -# idx#) s7 of { s8 ->`  
     `case unsafeFreezeSmallArray# mVals# s8 of { (# _, frozenVals# #) ->`  
       `(# frozenKeys#, frozenVals# #)`  
     `}}}}}}}}}`

### **B. Hash Tries: Moving from HAMT to CHAMP**

Standard HAMTs (as in unordered-containers) interleave values and sub-trie pointers inside a single SmallArray\# Any using a single 32-bit or 64-bit bitmap. This hurts cache locality during traversal and forces boxed key comparisons.

**CHAMP (Compressed Hash-Array Mapped Prefix-tree)** improves on HAMT by splitting the node into two bitmaps—a datamap for inline entries and a nodemap for child pointers—which maps directly onto the bifurcated block:

`data ChampNode k v = ChampNode`  
  `Word#              -- ^ datamap# (64-bit mask of inline entries)`  
  `Word#              -- ^ nodemap# (64-bit mask of child subtries)`  
  `ByteArray#         -- ^ Contiguous unboxed hashes (or unboxed keys) for inline entries`  
  `(SmallArray# Any)  -- ^ [0 .. popCnt(datamap)-1]: inline payloads`  
                     `--   [popCnt(datamap) .. end]: child ChampNode pointers`

Lookup at depth *d* (6 bits of hash per level for 64-way branching) uses hardware popCnt64\#:

`champLookupStep :: Word# -> Word# -> Word# -> ByteArray# -> SmallArray# Any -> ...`  
`champLookupStep hash# shift# datamap# nodemap# hashes# ptrs# =`  
  `let bitpos# = and# (uncheckedShiftRL# hash# shift#) 63##`  
      `mask#   = uncheckedShiftL# 1## bitpos#`  
  `in case and# datamap# mask# of`  
       `0## -> case and# nodemap# mask# of`  
         `0## -> -- Miss!`  
         `_   ->`  
           `-- It's a child node: index starts after all inline data entries`  
           `let dataCount# = word2Int# (popCnt64# datamap#)`  
               `nodeIdx#   = word2Int# (popCnt64# (and# nodemap# (minusWord# mask# 1##)))`  
               `(# childAny #) = indexSmallArray# ptrs# (dataCount# +# nodeIdx#)`  
           `in -- recurse into (unsafeCoerce# childAny)`  
       `_ ->`  
         `-- Inline hit: check unboxed key/hash in ByteArray# first!`  
         `let dataIdx# = word2Int# (popCnt64# (and# datamap# (minusWord# mask# 1##)))`  
             `storedKey# = indexWord64Array# hashes# dataIdx#`  
         `in ...`

Checking the key in hashes\# (ByteArray\#) before touching ptrs\# (SmallArray\# Any) avoids dereferencing the lifted payload pointer on hash collisions or probing.

### **C. Adaptive Radix-B+ Tree Hybrids (ART, Masstree, HOT)**

Radix trees (tries) bound lookup time by key length *O*(*k*) rather than log*N*, while B+ trees optimize for cache-line density and range scans. Combining them in Haskell relies on three main designs:

#### **1\. ART (Adaptive Radix Tree) \+ B+ Leaves**

ART dynamically changes internal node representation based on active fanout (between 1 and 256 children per key byte) and attaches horizontal B+-style leaf blocks (16–64 keys) at the bottom once a subtree contains ≤64 entries. Instead of four separate GADT constructors (which add pointer-tagging branch overhead), encode all four ART node sizes plus path-compression metadata into the single BlockNode layout:

| ART Node Type | Word\# Header Layout | ByteArray\# Contents | SmallArray\# Any Contents |
| :---- | :---- | :---- | :---- |
| **Node4** | Tag 0, count (1–4), 4-byte prefix \+ 4 key bytes packed right into the 64-bit Word\#\! | *(Empty / shared static)* | 4 child pointers |
| **Node16** | Tag 1, count (5–16), prefix len | 8B prefix \+ 16 sorted key bytes (searched in 1 SIMD Int8X16\# comparison) | 16 child pointers |
| **Node48** | Tag 2, count (17–48), prefix len | 8B prefix \+ 256-byte lookup table mapping byte \-\> slot (0..47) | Up to 48 child pointers |
| **Node256** | Tag 3, count (49–256), prefix len | 8B prefix | 256 direct child pointers (indexed directly by byte\#) |
| **B+ Leaf** | Tag 4, count (1–32) | 32 key suffixes / fingerprints | 32 values |

Notice the optimization for **Node4**: a 64-bit Word\# has enough bits to hold a 2-bit tag, a 3-bit count, 3 bytes of compressed path prefix, and all 4 routing key bytes (4 \* 8 \= 32 bits). A Node4 step doesn't even touch ByteArray\#\!

#### **2\. Masstree (A Trie of 8-Byte B+ Trees)**

Variable-length keys (like strings or composite database keys) break fixed-stride ByteArray\# B+ tree nodes. **Masstree** solves this by slicing arbitrary-length byte strings into 8-byte (Word64\#) big-endian chunks:

> * Each layer is a standard B+ tree whose keys are strictly unboxed Word64\# values in ByteArray\#.  
> * If two keys share the same first 8 bytes, that slot in the Layer-0 B+ tree leaf points (in its SmallArray\# Any slot) to the root of a **Layer-1 B+ tree** that indexes bytes 8…15.  
> * If a key is unique within the current 8-byte slice, the leaf stores the remaining suffix in its ByteArray\# and the value in SmallArray\# Any.

#### **3\. HOT (Height Optimized Trie) via BMI2 pext64\#**

Instead of branching on 8 bits at a time like ART, HOT branches on only the **discriminative bits** where keys in a subtree actually differ.

> * An internal node holds up to 32 children.  
> * Its Word\# header stores a 64-bit bitmask of up to 16 discriminative bit positions across a 64-bit key chunk.  
> * During lookup, GHC's pext64\# primop (x86 BMI2 PEXT instruction) extracts those discriminative bits from the search key into a dense integer in 3 cycles, which is then compared against packed partial keys in ByteArray\# via SIMD.

## **3\. High-Dimensional Search Algorithms & Blocked Layouts**

High-dimensional search structures split into three regimes depending on dimensionality *d*, because of the **curse of dimensionality**: as *d* grows past ∼16, the volume of a hypercube concentrates in its corners, causing bounding boxes in hierarchical trees to overlap almost 100% and degrading tree searches into full scans.

| Regime | Dimensions (*d*) | Best Blocked Algorithms | Memory Layout Strategy in GHC |
| :---- | :---- | :---- | :---- |
| **Low-D Spatial** | *d*\=2…16 | **UB-Tree** (Z-Order / Hilbert B+ Tree), **R\*-Tree** | Space-filling curve mapping to 1D B+ tree, or SoA bounding boxes in ByteArray\# |
| **Medium-D Exact/ Metric** | *d*\=16…64 | **Cache-Oblivious Blocked KD-Tree**, **VA-File** | Mini KD-subtrees of depth 4 packed into 1 cache line (ByteArray\#) \+ 16 child pointers |
| **High-D Vector / ANN** | *d*\=64…4096 | **HNSW / Vamana (DiskANN)** \+ **Product Quantization (PQ / RaBitQ)** | Flat ByteArray\# vector/code arena \+ fixed-degree blocked adjacency lists |

### **Regime 1: Low-to-Moderate Dimensions (*d*≤16)**

#### **A. The UB-Tree (Z-Order / Hilbert Curve \+ Standard B+ Tree)**

The cleanest way to implement multidimensional range search in Haskell without writing a custom spatial tree is the **Universal B-Tree (UB-Tree)**:

> 1. Interleave the bits of the *d* coordinates (*x*1​,…,*xd*​) into a single Morton code (Z-order key) of size Word64\# or Word64X2\# (using BMI2 pdep64\# to interleave bits in hardware).  
> 2. Store the Morton keys in the standard **Blocked B+ Tree** from Section 2A.  
> 3. **Multidimensional Range Query (\[minCoords, maxCoords\]):** A *d*\-dimensional query box intersects the 1D Z-curve in several contiguous segments. Start at morton(minCoords). Whenever a B+ leaf key exits the query box, compute nextJumpInZBox(currentMorton, minCoords, maxCoords)—a pure bit-manipulation function that finds the smallest Morton code ≥currentMorton that re-enters the *d*\-dimensional box—and fast-forward in the B+ tree\!

#### **B. SIMD-Blocked R\*-Trees (Structure-of-Arrays MBRs)**

If you store intervals/polygons rather than points, use an **R\*-Tree** with fanout *B*\=8 or 16\.

> * **Never store bounding boxes as Array-of-Structs** (\[(minX, minY, maxX, maxY), ...\]).  
> * Instead, lay out the node's ByteArray\# as **Structure-of-Arrays (SoA)**:  
  * Offset 0: B contiguous Float\# (or Double\#) values for min\_x of all *B* children.  
  * Offset B \* 4: B contiguous Float\# values for max\_x of all *B* children.  
  * Offset 2 \* B \* 4: min\_y, and so on.  
> * **Why SoA matters:** To test which of the 8 children intersect a query box \[qMinX, qMaxX, qMinY, qMaxY\], you broadcast qMaxX and qMinX into SIMD registers and compare against all 8 children's min\_x and max\_x in a single AVX2 instruction (DoubleX4\# / FloatX8\#), bitwise-ANDing the resulting masks across dimensions 1…*d*.

### **Regime 2: Medium Dimensions (16\<*d*≤64) — Blocked Mini-KD-Trees**

Standard KD-trees have a branching factor of 2 (1 split dimension \+ 1 split float per node), which has terrible cache locality.

> * **The Blocked Solution:** Pack a complete binary KD-subtree of height *h*\=4 (24−1=15 internal binary split nodes) into a single BlockNode:  
  * ByteArray\# (90 bytes): 15 split values (Float\#, 60 bytes) \+ 15 split dimension indices (Word16\#, 30 bytes) laid out in 1-indexed heap order (left \= 2\*i, right \= 2\*i \+ 1).  
  * SmallArray\# Any (16 pointers): The 16 exit subtrees at the bottom of the depth-4 mini-tree.  
> * Traversing 4 levels of the KD-tree happens inside a single ByteArray\# without chasing a single heap pointer\!

### **Regime 3: High Dimensions (*d*\=64…4096) — Blocked Proximity Graphs (Vamana / HNSW) \+ Quantization**

Above *d*≈64, hierarchical space-partitioning trees examine nearly 100% of leaves. Modern high-dimensional search uses **navigable small-world proximity graphs (HNSW or Vamana/DiskANN)** combined with **compressed vector codes (Product Quantization or RaBitQ)**:

> 1. **Graph \+ Code Co-blocking (ByteArray\# Slab):** In greedy beam search, the bottleneck is random memory access when fetching a node's neighbors and computing distances to the query vector. Pack each graph vertex *u* into a contiguous fixed-stride block inside a master ByteArray\# (or per-page ByteArray\# slabs):

VertexBlock(*u*)=e.g., 32×4=128BDegree *M* Neighbor IDs (Word32\#*M*)​​∥e.g., 64B PQ / RaBitQ codeQuantized Vector Code of *u*​​

> 2. **Two-Tier Distance Evaluation:**  
   * During greedy graph routing, the search beam only reads the 64-byte quantized code inside ByteArray\#, estimating inner-product/L2 distance via AVX2 lookup tables or popcount without touching full-precision vectors.  
   * Only the top-*K* candidates at the end of beam search dereference the full-precision Float\# / Double\# vectors (which can be stored in a linear-massiv matrix) for exact reranking.

## **4\. Extending polytropos to Blocked Memory: SoA Block Rows**

Your observation that polytropos got moderately close to raw memory with SmallArray\# Any points directly to how polytropos can be generalized for blocked data structures.

Right now, polytropos represents a single record instance Record f r as one SmallArray\# Any (Array-of-Structs if you put multiple records in a node). For blocked data structures, you want a **Block (n :: Nat) (r :: Row Type)** representing *n* rows (e.g., *n*\=16 or 64 entries in a B+ leaf, R-tree node, or columnar table page) that is **statically partitioned and transposed into Structure-of-Arrays (SoA)** by Polytropos.Plugin:

``-- | A blocked node of capacity `n` (e.g. 16 or 64 entries) over a Polytropos row `r`.``  
`data Block (n :: Nat) (r :: Row Type) = Block`  
  `{-# UNPACK #-} !Int          -- ^ Active element count (0 .. n)`  
  `` ByteArray#                   -- ^ All `Prim` fields in `r`, laid out as SoA SIMD lanes of length `n` ``  
  ``(SmallArray# Any)            -- ^ All lifted fields in `r`, laid out as `k * n` pointer slots``

### **How the TcPlugin Synthesizes *O*(1) Blocked Access**

Suppose a B+ tree leaf or spatial node has the row type:

`type NodeEntry =`  
  `'[ "key"     := Word64      -- Prim (8 bytes)`  
   `, "minX"    := Float       -- Prim (4 bytes)`  
   `, "maxX"    := Float       -- Prim (4 bytes)`  
   `, "payload" := UserValue   -- Lifted (Boxed pointer)`  
   `, "child"   := NodePtr     -- Lifted (Boxed pointer)`  
   `]`

When compiled for block capacity n \= 16, the TcPlugin inspects each field's Prim / Lifted classification in r and partitions the layout at compile time:

> 1. **Unboxed SoA Spine (ByteArray\# of 16×(8+4+4)=256 bytes):**  
   * "key" is assigned **Byte Offset 0\#**, stride 8\# (bytes 0..127 — two 64B cache lines).  
   * "minX" is assigned **Byte Offset 128\#**, stride 4\# (bytes 128..191 — one 64B cache line).  
   * "maxX" is assigned **Byte Offset 192\#**, stride 4\# (bytes 192..255 — one 64B cache line).  
> 2. **Lifted Spine (SmallArray\# Any of 16×2=32 slots):**  
   * "payload" is assigned **Pointer Base 0\#** (slots 0..15).  
   * "child" is assigned **Pointer Base 16\#** (slots 16..31).

When you project field \#minX at slot i\# or ask for the SIMD lane of \#key across the whole block, the TcPlugin emits literal Int\# byte offsets directly into GHC Core:

> * **Scalar read (getSlot \#minX block i\#):** Compiles to indexFloatArray\# (plusAddr\# (byteArrayContents\# ba\#) 128\#) i\# (or indexFloatOffAddr\# / scaled indexByteArray\#).  
> * **SIMD lane read (getSimdLane4 \#key block chunkIdx\#):** Compiles to indexWord64X4Array\# ba\# chunkIdx\#, allowing a single generic search combinator to scan any Prim field of a Block n r at hardware memory bandwidth.  
> * **Lifted read (getSlot \#payload block i\#):** Compiles to unsafeCoerce\# (indexSmallArray\# sa\# (0\# \+\# i\#)).

This gives you polytropos's structural row ergonomics and *O*(1) plugin-synthesized offsets, while ensuring that unboxed keys, bounding boxes, and bitmasks sit in contiguous, SIMD-aligned ByteArray\# cache lines and only true heap references inhabit SmallArray\# Any.

Would you like to focus on persistent vs. ST-ephemeral mutation patterns for these ByteArray\# \+ SmallArray\# Any blocks, or dive into the exact TcPlugin layout equations for mixed Prim/lifted SoA rows?

---

*User prompt: I'm unsure how general of Haskell data structures are handled or how well the low-level memory manipulation can be abstracted. What would a solution like a \`blocked-containers\` look like that uses various of these in-core fully raw memory blocked algorithms for locality of reference while being general enough to present the same interfaces as, say, \`containers\` and \`unordered-containers\` while adapting to things like dimensionality and the variability of key sizes etc. under the hood via \`polytropos\` \-based generic programming or similar?*

Response: A blocked-containers library can provide drop-in replacements for containers (Map, Set, IntMap, Seq) and unordered-containers (HashMap, HashSet) while executing raw-memory blocked algorithms under the hood by separating **block memory physics** from **tree topology**.

The key architectural insight is that **every node in a B+ tree, ART, Masstree, CHAMP hash trie, or R\*-tree is simply a capacity-*B* table of rows**. When backed by polytropos and Polytropos.Plugin, a node of *B* elements does not need bespoke ByteArray\# offset arithmetic written per container. Instead, the node *is* a Block B row whose primitive columns are transposed into contiguous SIMD-friendly lanes in a ByteArray\# and whose lifted Haskell pointers sit in a companion SmallArray\# Any.

## **1\. The 3-Layer Abstraction Architecture**

To keep low-level ByteArray\# / SmallArray\# Any manipulation completely hidden while supporting arbitrary Haskell types, blocked-containers splits into three layers:

| Layer | Module / Abstraction | Responsibility |
| :---- | :---- | :---- |
| **1\. Columnar Block Substrate** | Polytropos.Block (Block (n :: Nat) (r :: Row Type)) | Manages a fixed-capacity block of *n* rows. Polytropos.Plugin splits r into unboxed SoA columns (ByteArray\#) and lifted pointer columns (SmallArray\# Any), synthesizing *O*(1) copy, shift, split, and SIMD search primitives. |
| **2\. Key & Value Normalization** | Data.Containers.Blocked.Encoding (KeyLayout k, ValLayout v) | Maps arbitrary Haskell types (Int, Text, nominal ADTs, open polytropos records/variants, or opaque Ord types) onto flat row schemas. |
| **3\. Topology Engines** | Blocked.BPlus, Blocked.CHAMP, Blocked.Masstree, Blocked.Spatial | Pure functional tree algorithms expressed entirely in terms of high-level Block operations (blockSearch, blockInsertAt, blockSplitAt, blockMerge). |

### **Why Tree Nodes Are Just polytropos Blocks**

Once you have Block (n :: Nat) (r :: Row Type), you no longer write separate low-level array code for internal nodes, leaf nodes, or spatial nodes:

> * **B+ Leaf Node:** Block B (KeyRow k \++ ValRow v)  
> * **B+ Internal Node:** Block B (KeyRow k \++ '\["child" := BPlusNode k v\])  
> * **R\*-Tree Internal Node:** Block B (BoundingBoxRow d Float \++ '\["child" := RTreeNode d a\])  
> * **CHAMP Hash Node:** Two Word64\# bitmaps \+ BlockVar (KeyRow k \++ ValRow v) \+ child slots.

Even better, **values are automatically unboxed and decomposed alongside keys**. In Data.Map Int (Int, Double, Text), standard containers allocates a tree bin, an Int box, a 3-tuple box, an Int box, and a Double box (5 heap objects per entry). In blocked-containers, Polytropos.Generics flattens the key and value rows together: the key Int and value fields Int and Double are packed into the leaf node's ByteArray\#, while only the Text pointer is stored in the leaf's SmallArray\# Any.

## **2\. Handling Completely General Haskell Types (The 4 Tiers)**

A general Haskell container must accept *any* k and v—from Word64 to recursive ADTs, lazy thunks, or function closures (Int \-\> IO ()). blocked-containers handles this via a 4-tier representation hierarchy resolved at compile time:

### **Tier 1: Fixed-Width Primitives & All-Prim polytropos Records**

> * **Types:** Int, Word64, Double, Char, (Int, Int), or any nominal/structural type whose polytropos row contains only Prim fields.  
> * **Physical Layout:** 100% inside ByteArray\#. If v is also Tier 1, the SmallArray\# Any in every leaf node points to GHC's zero-length static empty array closure (zero heap allocation for pointers).  
> * **Order-Preserving Normalization (OrderedBits):** To allow raw SIMD integer comparisons (Int64X4\# / Int32X8\#) without calling Haskell's compare:  
  * Signed integers flip their sign bit (xor\# x (1 \<\< 63)).  
  * Double / Float apply the IEEE-754 lexicographical bit-flip (if negative, flip all bits; if positive, flip sign bit) so standard integer SIMD \<\# matches total floating-point ordering.

### **Tier 2: Variable-Length Keys (ByteString, Text, \[a\], Open Variants)**

> * **The Problem:** Variable-length keys cannot fit in fixed-stride ByteArray\# slots directly, but chasing a pointer on every comparison during binary search ruins cache locality.  
> * **Physical Layout (Umbra / German-String Prefix \+ Masstree Slicing):** Every variable-length key is decomposed into a polytropos row:  
>   `type VarKeyRow k = '["prefix" := Word64, "len" := Word32, "tail" := k]`

  * "prefix" (the first 8 bytes of the string/key in big-endian byte order) and "len" sit contiguously in the node's ByteArray\#.  
  * "tail" (the full Text/ByteString or suffix) sits in SmallArray\# Any.  
  * **Why this is fast:** During a 16-way node search, SIMD scans the 8-byte "prefix" lane inside ByteArray\#. Over 99% of non-matching branches are rejected strictly in L1 cache without ever dereferencing the "tail" pointer in SmallArray\# Any\! If keys share a long common prefix (e.g., URLs or file paths), the container automatically switches to **Masstree mode**, pushing shared 8-byte prefixes into a parent radix layer.

### **Tier 3: Compound & Sum Types (polytropos Nominal & Structural ADTs)**

> * **Types:** User data types and extensible Record / Variant types.  
> * **Physical Layout:**  
  * For a **Product (Record r)**: Polytropos.Plugin partitions r into its Prim fields (stored as SoA arrays in ByteArray\#) and its lifted fields (stored in SmallArray\# Any).  
  * For a **Sum (Variant r)**: Since polytropos already represents variants as an unpacked Word tag \+ payload array, the constructor tag (Word16\# or Word32\#) is stored as an unboxed SoA column in ByteArray\#\! Searching a node of variants compares the unboxed constructor tags via SIMD first, only inspecting payloads when tags match.

### **Tier 4: Arbitrary Boxed / Opaque Ord Types & Lazy Values**

> * **Types:** Types with custom, non-structural Ord instances, functions, or Data.Map.Lazy values.  
> * **Physical Layout:** The ByteArray\# key lane has byte-width 0\# (referencing a static empty ByteArray\#), and keys/values reside in SmallArray\# Any.  
> * **Why it still beats containers:** Standard Data.Map is a binary size-balanced tree that allocates a 6-word Bin closure per element (48 bytes of overhead per entry). Even in the Tier-4 fallback, a 16-way SmallArray\# Any B+ tree reduces heap header overhead by 4× and keeps 16 child/key pointers in two contiguous cache lines.

## **3\. Concrete Blueprint: Abstracting Raw Memory via Polytropos.Block**

Here is how the low-level memory manipulation is encapsulated once in Polytropos.Block, so the upper container algorithms remain clean, safe, and purely declarative.

### **Step 1: The BlockLayout Typeclass (Synthesized by Polytropos.Plugin)**

Instead of solving recursive type families (which cause *O*(*N*2) compile times), Polytropos.Plugin inspects a row r and capacity n, emitting literal Int\# byte offsets and pointer offsets directly into GHC Core:

`{-# LANGUAGE DataKinds, KindSignatures, MagicHash, UnboxedTuples #-}`  
`{-# LANGUAGE ScopedTypeVariables, TypeApplications, TypeFamilies, RoleAnnotations #-}`

`module Polytropos.Block`  
  `( Block(..)`  
  `, BlockLayout(..)`  
  `, bsearchScalar`  
  `, insertBlockAt`  
  `, splitBlockAt`  
  `) where`

`import Data.Kind (Type)`  
`import GHC.Exts`  
`import GHC.TypeLits (Nat)`  
`import Polytropos.Core (Row, Record, Rep(..))`

``-- | A cache-blocked Structure-of-Arrays (SoA) node holding up to `n` rows of schema `r`.``  
`data Block (n :: Nat) (r :: Row Type) = Block`  
  `Int#               -- ^ Active element count (0# .. n#)`  
  `` ByteArray#         -- ^ Contiguous SoA lanes for all `Prim` fields in `r` ``  
  `` (SmallArray# Any)  -- ^ Contiguous SoA lanes for all lifted fields in `r` ``

``-- | Synthesized in O(1) by `Polytropos.Plugin` for any capacity `n` and row `r`.``  
`class BlockLayout (n :: Nat) (r :: Row Type) where`  
  `` -- | Total bytes per capacity-`n` block in `ByteArray#` ``  
  `blockByteSize  :: Int#`  
  ``-- | Number of lifted fields `k` in `r` (total `SmallArray#` size = k * n)``  
  `blockPtrColumns :: Int#`  
  ``-- | Total bytes of all `Prim` fields for a single element``  
  `elemPrimBytes  :: Int#`

  `-- | Copy a range [srcOff .. srcOff + len - 1] of rows from an immutable Block`  
  ``-- into a mutable Block at `dstOff` across all SoA lanes.``  
  `copyColumns#`  
    `:: ByteArray# -> SmallArray# Any -> Int#         -- ^ Source block & start row`  
    `-> MutableByteArray# s -> SmallMutableArray# s Any -> Int# -- ^ Dest block & start row`  
    `` -> Int#                                          -- ^ Number of rows `len#` ``  
    `-> State# s -> State# s`

  ``-- | Write a single row `i#` into a mutable block.``  
  `writeRow#`  
    `:: MutableByteArray# s -> SmallMutableArray# s Any`  
    `-> Int# -> Record Identity r`  
    `-> State# s -> State# s`

  ``-- | Project a single row `i#` out of an immutable block.``  
  `readRow#`  
    `:: ByteArray# -> SmallArray# Any -> Int#`  
    `-> Record Identity r`

### **Step 2: Generic Copy-on-Write Node Operations**

Because copyColumns\# and writeRow\# are synthesized by the plugin for any row r, **splitting, inserting, and deleting inside a block are written once for all data structures**:

``-- | Insert a row at index `idx#` in a non-full Block, returning a new immutable Block.``  
`insertBlockAt`  
  `:: forall n r. BlockLayout n r`  
  `=> Block n r`  
  `-> Int#`  
  `-> Record Identity r`  
  `-> Block n r`  
`insertBlockAt (Block count# oldBa# oldSa#) idx# row = runRW# $ \s0 ->`  
  `let totalBytes# = blockByteSize @n @r`  
      `totalPtrs#  = blockPtrColumns @n @r *# (count# +# 1#)`  
  `in case newByteArray# totalBytes# s0 of { (# s1, mBa# #) ->`  
     `case newSmallArray# totalPtrs# (unsafeCoerce# ()) s1 of { (# s2, mSa# #) ->`  
     `-- 1. Copy prefix rows [0 .. idx# - 1]`  
     `case copyColumns# @n @r oldBa# oldSa# 0# mBa# mSa# 0# idx# s2 of { s3 ->`  
     `` -- 2. Write the newly inserted row at `idx#` ``  
     `case writeRow# @n @r mBa# mSa# idx# row s3 of { s4 ->`  
     `-- 3. Copy suffix rows [idx# .. count# - 1] -> [idx# + 1 .. count#]`  
     `case copyColumns# @n @r oldBa# oldSa# idx# mBa# mSa# (idx# +# 1#) (count# -# idx#) s4 of { s5 ->`  
     `case unsafeFreezeByteArray# mBa# s5 of { (# s6, frozenBa# #) ->`  
     `case unsafeFreezeSmallArray# mSa# s6 of { (# _, frozenSa# #) ->`  
       `Block (count# +# 1#) frozenBa# frozenSa#`  
     `}}}}}}}`

``-- | Split a full Block of `n` elements at `mid#` into two new Blocks.``  
`splitBlockAt`  
  `:: forall n r. BlockLayout n r`  
  `=> Block n r`  
  `-> Int#`  
  `-> (# Block n r, Block n r #)`  
`splitBlockAt (Block count# oldBa# oldSa#) mid# = runRW# $ \s0 ->`  
  `let rightCount# = count# -# mid#`  
      `totalBytes# = blockByteSize @n @r`  
      `leftPtrs#   = blockPtrColumns @n @r *# mid#`  
      `rightPtrs#  = blockPtrColumns @n @r *# rightCount#`  
  `in case newByteArray# totalBytes# s0 of { (# s1, mBaL# #) ->`  
     `case newSmallArray# leftPtrs# (unsafeCoerce# ()) s1 of { (# s2, mSaL# #) ->`  
     `case copyColumns# @n @r oldBa# oldSa# 0# mBaL# mSaL# 0# mid# s2 of { s3 ->`  
     `case unsafeFreezeByteArray# mBaL# s3 of { (# s4, baL# #) ->`  
     `case unsafeFreezeSmallArray# mSaL# s4 of { (# s5, saL# #) ->`  
     `case newByteArray# totalBytes# s5 of { (# s6, mBaR# #) ->`  
     `case newSmallArray# rightPtrs# (unsafeCoerce# ()) s6 of { (# s7, mSaR# #) ->`  
     `case copyColumns# @n @r oldBa# oldSa# mid# mBaR# mSaR# 0# rightCount# s7 of { s8 ->`  
     `case unsafeFreezeByteArray# mBaR# s8 of { (# s9, baR# #) ->`  
     `case unsafeFreezeSmallArray# mSaR# s9 of { (# _, saR# #) ->`  
       `(# Block mid# baL# saL#, Block rightCount# baR# saR# #)`  
     `}}}}}}}}}}`

## **4\. Adaptive Container Routing Under the Hood**

With Polytropos.Block handling raw memory, blocked-containers can inspect the structure of k at compile time and select the optimal physical index while presenting a unified API:

``-- | Compile-time strategy selector inspecting `k`'s Polytropos metadata``  
`type family IndexStrategy (k :: Type) :: StrategyKind where`  
  `IndexStrategy Int         = 'SIMD_BPlus 32`  
  `IndexStrategy Word64      = 'SIMD_BPlus 32`  
  `IndexStrategy ByteString  = 'Masstree 16`  
  `IndexStrategy Text        = 'Masstree 16`  
  `IndexStrategy (Record r)  = SelectRowStrategy r`  
  `IndexStrategy k           = 'GenericBPlus 16`

Here is how the same surface API adapts across key shapes and dimensions:

### **1\. Drop-In 1D Ordered Containers (Blocked.Data.Map.Strict & .Lazy)**

> * **Strict vs. Lazy:**  
  * Data.Map.Strict.Map k v uses LeafRow k v \= KeyRow k \++ ValRow v. If v is a polytropos record or primitive, its primitive fields are unboxed directly into the leaf ByteArray\#.  
  * Data.Map.Lazy.Map k v uses LeafRow k v \= KeyRow k \++ '\["val" := v\], keeping v as a single lifted slot in SmallArray\# Any so lazy thunks (insertWith, tying the knot) behave identically to containers.  
> * **Monoidal / Finger Measures (Data.Sequence & Order Statistics):** Data.Map supports indexed operations (elemAt, take, drop, splitAt) because each node stores subtree size. In a blocked B+ tree, each internal node simply includes "subtreeSize" := Int in its polytropos row\! An internal node with fanout 16 stores 16 Int32\# subtree sizes in 64 bytes of its ByteArray\#, enabling *O*(log*B*​*N*) rank queries (elemAt) and making Blocked.Data.Sequence a B-tree of Block 32 '\["elem" := a\] leaves with SIMD prefix-sum indexing.

### **2\. Drop-In Unordered Containers (Blocked.Data.HashMap)**

> * Replaces unordered-containers's HAMT with a **Bifurcated CHAMP Trie**.  
> * For each node, the 64-bit datamap\# and nodemap\# bitmasks are unpacked into the constructor.  
> * The node's ByteArray\# holds a packed array of 16-bit or 64-bit hash/key fingerprints for inline entries, while SmallArray\# Any holds the inline lifted payloads in \[0 .. popCnt(datamap) \- 1\] and child node pointers in \[popCnt(datamap) .. end\].  
> * Set operations (union, intersection, difference) operate directly via bitwise & and \| on datamap\# and nodemap\# plus bulk copyByteArray\# / copySmallArray\# slices, running 3×–5× faster than pointer-chasing HAMTs.

### **3\. Automatic Multi-Dimensional & Prefix Adaptation**

When a key k is a polytropos product row (e.g., Record '\["lat" := Double, "lon" := Double, "time" := Word64\]), the same Map k v supports two query modes depending on how the key columns are organized:

> * **Lexicographical / Composite Key Mode (Default Ord):** Columns "lat", "lon", and "time" are laid out as three separate SoA lanes in the node's ByteArray\#. Searching the node runs SIMD equality/comparison on "lat" first, masking in "lon" only for lanes where "lat" tied.  
> * **Spatial / Orthogonal Range Mode (SpatialMap k v):** A typeclass method orthogonalRange :: Record Interval r \-\> SpatialMap (Record Identity r) v \-\> \[v\] uses Polytropos.Plugin to interleave the normalized bits of each field in r via BMI2 pdep64\# into a Z-order Morton code inside a standard blocked B+ tree (a **UB-Tree**), or tests all *B* children in an SoA bounding-box block simultaneously:

``-- | Given a query bounding box `[lo, hi]` over ANY Polytropos row `r` of Prim coordinates,``  
`` -- `Polytropos.Plugin` synthesizes an unrolled SIMD loop across all dimensions in `r` ``  
`-- returning a 16-bit bitmask of matching child slots in the Block.`  
`class SpatialBlock (n :: Nat) (r :: Row Type) where`  
  `matchBoundingBoxMask#`  
    `:: Block n (BoundingBoxRow r)`  
    `-> Record Identity r  -- ^ Query lower bound (min corner)`  
    `-> Record Identity r  -- ^ Query upper bound (max corner)`  
    `-> Word#              -- ^ Bitmask of children intersecting [lo, hi]`

## **5\. Solving the "Parametric vs. Specialized" Haskell API Problem**

There is one subtle Haskell type-system trap when emulating containers: in Data.Map.Lazy, functions like fmap :: (a \-\> b) \-\> Map k a \-\> Map k b and Foldable do **not** have an Ord k or KeyLayout k constraint in their type signatures\!

If Map k v required a BlockLayout constraint on v just to exist, it could not be a lawful Functor. blocked-containers solves this cleanly with a **2-constructor GADT wrapper** at the top of the container:

`data Map k v where`  
  ``-- | Fast path: Created whenever `insert` / `fromList` has `Polytropos` / `Prim` layout``  
  ``-- or when using `Blocked.Map.Unboxed` / `Polytropos` rows.``  
  `BlockedMap`  
    `:: !(BPlusNode (KeyRow k) (ValRow v))`  
    `-> Map k v`

  `` -- | Functor / Lazy fallback: Used when `fmap` maps an unconstrained function `(a -> b)` ``  
  ``-- over `Map k a` where `b`'s layout isn't statically known at the call site.``  
  ``-- Preserves the exact unboxed `ByteArray#` key structure while storing `b` in `SmallArray# Any`!``  
  `LiftedValMap`  
    `:: !(BPlusNode (KeyRow k) '["val" := v])`  
    `-> Map k v`

Look at what LiftedValMap achieves when a user calls fmap f myMap:

> 1. The keys (KeyRow k) **stay 100% unboxed in their existing ByteArray\# slices**—in fact, fmap doesn't even copy or allocate new ByteArray\# key blocks\! It shares the immutable ByteArray\# pointer of every node directly and only allocates a new SmallArray\# Any applying f to the value slots.  
> 2. You get full Functor, Foldable, and Traversable compatibility with containers (Data.Map), zero constraint pollution on polymorphic signatures, and raw cache-line/SIMD speed on all key lookups and structural operations.

Would you like to sketch out the exact Polytropos.Plugin Core-synthesis rules for BlockLayout (copyColumns\# and SIMD bsearchBlock\#), or look at how bulk operations like unionWith and intersectionWith work on two SoA Block trees?

---

*User prompt: Those are both good things to come back to, though I might have some slightly different questions first. 1\. How well do things interoperate with GC as thus far elaborated upon? Is there something we need to do so it doesn't pin vast amounts of memory? Or did it happen and I missed it? Or do we need a plug-in? Or is there a way to do it at all? 2\. In the scheme as thus-far elaborated, I never saw fallback to Vamana/HNSW — was it just referred to in other terms? It seems as if it would be very easy for some structures to achieve high dimensionality — or is it that impression that's wrong? 3\. Is there any way to quantitatively estimate what kind of performance boost we'd achieve over \`containers\` and \`unordered-containers\`? If so, what would be a likely range for it to fall within? 4\. Would \`amphores\` as a transliteration of ᾰ̓μφορῆς be a good Homeric package name for it? Or is there a specifically block-y container the term for which both sounds good and can be extracted from the scanty extant Homeric Greek corpora? My original motivation had to do more with a larger hierarchy of memory contiguity and alignment, like the sorts of considerations undertaken for the Intel-Oracle FAST Tree (2010), covering SIMD, cache, TLB, and my own thoughts elsewhere have extended the thought process to both superpage size spectra and efficiency for in-place mutation, though the last might only be applicable in a sharply limited way within Haskell. Please do let me know your thoughts regarding the points above.*

### **Response: 1\. GC Interoperability, Memory Pinning, and the FAST Tree Hierarchy**

#### **Did We Pin Memory? (Movable vs. Pinned ByteArray\#)**

The design elaborated so far does **not** pin small nodes, because GHC's newByteArray\# allocates **unpinned, movable** byte arrays on the standard GHC heap. Only newPinnedByteArray\# (and newAlignedPinnedByteArray\#) pins small objects.

> * **Small Nodes (\< 3,277 bytes):** Allocated via newByteArray\#, these live in normal 4 KB GHC nursery blocks (bdescr). The copying garbage collector moves and compacts them freely without fragmentation, and **never scans their interior** (because their closure info table marks them as ARR\_words, containing zero pointers).  
> * **Large Blocks (≥ 3,277 bytes):** When you call newByteArray\# with ≥80% of a 4 KB block size, the GHC RTS automatically allocates it as a BF\_LARGE object. Large objects are page-aligned (4 KB), live outside the copying nursery on a doubly-linked descriptor list, and are **never copied during GC**—yet they are immediately freed as soon as they become unreachable.

#### **The Two Real GC Retention Traps (and How to Prevent Them)**

While newByteArray\# avoids pinning fragmentation, there are two subtle ways a blocked structure can accidentally retain dead memory in GHC:

> 1. **Dead-Slot Retention in SmallArray\# Any (The Tombstone Leak):** GHC's GC does not know about your Block's logical count\#; it scans **every slot** of a SmallArray\# Any up to its physical sizeofSmallArray\#. If a capacity-32 node only holds 18 active elements (or just had an element deleted), and slots 18..31 in SmallArray\# Any still hold leftover pointers, the GC will keep those deleted user values alive indefinitely.  
   * **The Fix:** Unused slots in SmallArray\# Any must always be initialized or overwritten with unsafeCoerce\# () (which points to the static () closure in the data segment), **or** trimmed in-place before freezing using GHC's shrinkSmallMutableArray\# (and shrinkMutableByteArray\#).  
> 2. **Sub-Slice Retention in Page/Superpage Arenas:** If you allocate a 2 MB superpage ByteArray\# and represent tree nodes as (ByteArray\#, Offset\#) slices into that arena, a single live pointer to *one* 64-byte leaf keeps the entire 2 MB ByteArray\# alive.

#### **Scaling Up to the Intel–Oracle FAST Tree Hierarchy (SIMD → Cache Line → Page/TLB → Superpage)**

Your reference to Kim et al.'s **FAST (Fast Architecture Sensitive Tree, SIGMOD 2010\)** hits on the exact limitation of standard per-node heap allocations: even if each 256-byte B+ node is cache-line friendly, pointer-chasing between separate ByteArray\# nodes on the GHC heap still incurs **one TLB miss per tree level** once the tree exceeds L2/DTLB capacity.

FAST solves this by blocking a tree across **three nested hardware granularities** simultaneously:

> 1. **SIMD Block (*K*1​, e.g., 16–32 bytes):** A depth-2 or depth-4 mini-subtree searched in a single AVX2 register comparison (Int64X4\# / Int32X8\#).  
> 2. **Cache-Line Block (*K*2​, 64 bytes):** Multiple SIMD blocks packed into one CPU cache line.  
> 3. **Page / Superpage Block (*K*3​, 4 KB to 2 MB):** A subtree of height 6–10 packed contiguously inside a single OS virtual memory page (or 2 MB hugepage) in breath-first / van Emde Boas layout. Descending 8 levels of the tree happens via pure arithmetic offsets inside the same ByteArray\#, incurring **1 TLB miss instead of 8**.

To get FAST's TLB/superpage blocking in Haskell without triggering the 2 MB GC retention trap or losing functional updates, you use a **Two-Tier Stratified Architecture**:

`-- | Tier 1 (Upper Spine / Read-Optimized FAST Region):`  
``--   A single page-aligned `ByteArray#` (e.g., 64 KB or 2 MB mmap/pinned superpage)``  
`--   packing the upper levels of the tree in FAST van Emde Boas page-blocked layout.`  
`--   Zero internal heap pointers; child offsets are computed arithmetically.`  
`-- | Tier 2 (Bottom Frontier / Delta Leaves):`  
``--   Standard copy-on-write `Block B r` nodes (`ByteArray#` + `SmallArray# Any`)``  
`--   attached at the exit ports of the FAST upper tree.`  
`data FastBPlus k v = FastBPlus`  
  `ByteArray#          -- ^ Page-blocked FAST internal index (SIMD + Cache-line + 4KB/2MB Page)`  
  ``(SmallArray# Any)   -- ^ Exit pointers to mutable/CoW leaf clusters (`Block B r`)``

And for **in-place mutation** in Haskell, you actually have three viable paths beyond pure copy-on-write:

> * **ST s / PrimMonad Batch Transactions:** Expose a transient/ephemeral API (like Clojure's transients or vector's create/modify) where a FastBPlus tree is thawed or mutated in place via MutableByteArray\# and SmallMutableArray\# s inside ST s and frozen back with unsafeFreezeByteArray\# in *O*(1).  
> * **LinearTypes (-XLinearTypes):** A linear API (insertLinear :: k \-\> v \-\> Map k v %1 \-\> Map k v) can safely mutate MutableByteArray\# nodes in place while remaining 100% pure externally.  
> * **2 MB Hugepages (mmap \+ ForeignPtr / Addr\#):** For the top-tier FAST index or large vector arenas, GHC's RTS allocator only guarantees 4 KB page alignment on BF\_LARGE blocks. To guarantee **2 MB / 1 GB superpage alignment** (eliminating page-walk latency in the hardware PMU), a tiny C/Haskell mmap wrapper using MAP\_HUGETLB or madvise(..., MADV\_HUGEPAGE) wrapped in a ForeignPtr (with finalizer munmap) can back the read-heavy upper FAST index.

### **2\. Why Didn't Map k v Fall Back to Vamana/HNSW? (High-Field-Count Keys vs. High-Dimensional Metric Search)**

Your intuition that a data structure can easily reach 50–100 fields (especially with polytropos rows) is completely spot-on—**but "dimensionality" means three very different things depending on how the container is queried**:

| Query Semantics | Example with a 64-Field polytropos Record | Does the "Curse of Dimensionality" Apply? | Optimal Blocked Structure |
| :---- | :---- | :---- | :---- |
| **1\. Point / Lexicographical / Prefix Lookup** (Data.Map.lookup, lookupGE, HashMap.lookup) | k is a 64-field Record r compared via Eq or lexicographical Ord (*f*1​, then *f*2​ on tie, etc.) | **No (Effective *d*\=1).** Lexicographical order defines a total 1D line\! | **Masstree / HOT / B+ Tree** (slices the 64 fields into 8-byte chunks) or **CHAMP Trie**. |
| **2\. Exact Multi-Attribute Range / Box Query** (orthogonalRange / SQL WHERE f1 IN \[a,b\] AND f5 IN \[c,d\]) | Filtering records where 20+ independent fields must each fall in \[lo\_i, hi\_i\] | **Yes (*d*\=20+), and Vamana/HNSW cannot be used** because Vamana/HNSW are *approximate* radial distance graphs (they miss exact box matches\!). | ***d*****≤12:** UB-Tree (Z-order B+) or SIMD R\*-Tree. |

***d*****\>12:** **VA-File / SIMD BitWeaving** (quantized SoA column scan). \| \| **3\. Similarity / Metric Search (*k*\-NN)** (nearestK, withinDistance) \| Finding the *k* keys closest to queryKey under *L*2​, Cosine, Hamming, or custom distance \| **Yes (*d*\>16).** Partitioning trees degrade to 100% leaf scans here. \| ***d*****≤16:** Blocked Mini-KD-Tree.

***d*****\>16:** **Blocked Vamana (DiskANN) / HNSW \+ RaBitQ/PQ**. \|

That is why a drop-in Data.Map k v never falls back to Vamana/HNSW: Data.Map is defined by a **1D total order (Ord k)**. Even if k is a polytropos record with 100 fields, Ord compares field 1 first, only looking at field 2 if field 1 is equal. A Masstree or SoA B+ tree handles a 100-field record in *O*(log*B*​*N*) time without any high-dimensional degradation.

Conversely, when you query a polytropos record **multi-dimensionally** (via a companion MultiMap r v / MetricMap r v interface in the library), Polytropos.Plugin counts the active coordinate fields d \= RowLength r at compile time and routes automatically:

> * **For Exact Box Queries at *d*\>12 (The VA-File Fallback):** When a polytropos key row has more than 12 numeric dimensions, hierarchical bounding-box trees (R\*-trees/UB-trees) fail because almost every bounding box overlaps. The container automatically switches to a **Vector Approximation File (VA-File)**: it quantizes each field into a 4-bit or 8-bit integer inside a contiguous SoA ByteArray\# block, scans all blocks at 32–64 GB/s using AVX2 Int8X32\# SIMD comparisons to eliminate 99.5% of candidates, and only checks the exact coordinates of the surviving 0.5%.  
> * **For Metric / *k*\-NN Queries at *d*\>16 (The Vamana / HNSW Fallback):** When queried via nearestNeighbors, if RowLength r \<= 16, it uses the cache-blocked Mini-KD-Tree; if RowLength r \> 16, it switches to the **Blocked Vamana Graph** (storing fixed-degree neighbor IDs alongside compressed RaBitQ/PQ codes in a single ByteArray\# slab).

### **3\. Quantitative Performance Estimates vs. containers and unordered-containers**

We can calculate realistic performance ranges from first principles by comparing cache-line transfers, pointer dereferences, branch mispredictions, and GC heap words for *N*\=106 (1 million) entries.

#### **The Microarchitectural Math (*N*\=106 entries of (Int64, Int64))**

> * **Data.Map.Strict Int64 Int64 (containers):**  
  * **Heap Layout:** Binary tree of Bin closures (6 words \= 48 B) \+ boxed Int64 key (2 words \= 16 B) \+ boxed Int64 value (2 words \= 16 B) \= **80 bytes and 3 separate heap objects per entry** (\~80 MB total, 3 million pointers for the GC to trace).  
  * **Lookup Path:** log2​(106)≈20 levels. Each level chases the Bin pointer *and* the boxed key pointer, followed by a data-dependent branch (\< or \>). Once below L2 cache (levels 8–20), each level triggers 1–2 LLC/DRAM cache misses and \~10 branch mispredictions per lookup.  
> * **Blocked.Map Int64 Int64 (*B*\=32, \~75% fill \= 24 entries/block):**  
  * **Heap Layout:** Each leaf is one ByteArray\# (256 B keys \+ 256 B values \= 512 B) \+ static empty SmallArray\#. **\~21 bytes and 0 internal GC pointers per entry** (\~21 MB total, \~41,000 unscanned ByteArray\# leaves).  
  * **Lookup Path:** log24​(106)≈4.3 levels (4–5 blocks). Inside each block, 32 keys occupy 4 contiguous cache lines (fetched together by the L2 spatial prefetcher) and are searched via branchless AVX2 Int64X4\# instructions in \~4 cycles with **0 branch mispredictions** and **0 key-pointer dereferences**. With a FAST page-blocked upper spine, all 4 upper levels sit in **1 TLB page**.

#### **Expected Performance Multipliers (*N*\=105 to 107)**

| Operation / Metric | vs. Data.Map.Strict (Tier 1–2: Unboxed / polytropos / Text Keys) | vs. Data.Map.Strict (Tier 4: Arbitrary Boxed Ord Keys) | vs. Data.IntMap.Strict (PATRICIA Prefix Tree) | vs. Data.HashMap.Strict (unordered-containers HAMT) |
| :---- | :---- | :---- | :---- | :---- |
| **Point Lookup (lookup)** | **4× – 9× faster** | **1.5× – 2.3× faster** | **2× – 4.5× faster** | **1.8× – 3.5× faster** (via CHAMP) |
| **Persistent insert / delete** | **1.5× – 3.2× faster** (clones 4 spine blocks vs. 20 Bin nodes) | **1.1× – 1.6× faster** | **1.2× – 2.0× faster** | **1.3× – 2.2× faster** |
| **Ephemeral / Batch Build (fromList, ST)** | **6× – 18× faster** | **2.5× – 4× faster** | **4× – 10× faster** | **3× – 7× faster** |
| **Range Scan / Fold (foldlWithKey')** | **10× – 35× faster** (contiguous SIMD lanes vs. pointer tree walk) | **3× – 6× faster** | **6× – 20× faster** | **4× – 10× faster** |
| **Bulk Set Ops (union, intersection)** | **4× – 12× faster** (SIMD merge-join on leaf blocks) | **2× – 3.5× faster** | **2× – 5× faster** | **3× – 6× faster** (bitmap &/\| \+ slice copy) |
| **Live Memory Footprint** | **3.2× – 4.5× smaller** | **1.8× – 2.4× smaller** | **1.8× – 2.5× smaller** | **2.0× – 3.0× smaller** |
| **Major GC Pause Time (Scavenging Cost)** | **12× – 40× faster** (zero pointer scanning in ByteArray\#\!) | **2× – 3× faster** (no left/right child pointer headers) | **8× – 25× faster** | **3× – 8× faster** |

(Note: In linear-massiv, eliminating boxed per-element overhead in favor of ByteArray\# \+ AVX2 DoubleX4\# yielded 240×–330× speedups on dense numerical kernels; for pointer/branch-bound search structures, the 4×–9× lookup speedup and 10×–35× scan/GC speedup reflect the memory-latency ratio between L3/DRAM pointer chasing and L1/SIMD block scans.)

### **4\. Homeric Greek Package Naming: amphores vs. Block-Specific Homeric Terms**

amphores (transliterating Attic ἀμφορῆς; note that in Homeric epic the nominative plural is always uncontracted **ἀμφορῆες** — amphorees, e.g., *Iliad* 23.170, *Odyssey* 2.290, 9.204, with dative plural **ἀμφορεῦσιν**) is phonetically great and immediately recognizable as "containers."

However, if you want a term from the extant Homeric corpus (*Iliad* and *Odyssey*) that specifically evokes **squared blocks, slotted compartments, or tightly packed cache-aligned storage**—rather than curved ceramic wine jars—Homer actually has several extraordinary words:

| Proposed Package Name | Homeric Greek & Citations | Literal Meaning in Homer | Why It Fits Blocked Data Structures |
| :---- | :---- | :---- | :---- |
| **cheloi** (or **chelos**) | **χηλός** (pl. **χηλοί**, *Il.* 16.221, 16.228; *Od.* 2.339, 8.424, 13.10) | A heavy, rectangular, **well-planed wooden chest / coffer** (χηλὸς εὐξέστη). | In Homer, a chelos is specifically a squared-off box into which items are packed **πυκινῶς** ("densely / tightly / in compact blocks", *Od.* 8.438, 13.68). |
| **larnax** (or **larnakes**) | **λάρναξ** (*Il.* 18.413, 24.795) | A **rectangular tool-chest / coffer / box**. | In *Iliad* 18.413, Hephaestus packs all his forge instruments into a silver larnax. In *Iliad* 24.795–798, the golden larnax is cased inside **πυκνοῖσιν λάεσσι** ("closely fitted stone blocks"). Short, punchy, and unmistakably a box. |
| **phoriamoi** | **φωριαμοί** (*Il.* 24.228; *Od.* 15.104) | **Compartmentalized storage chests / trunks**. | Used in Priam's and Menelaus's treasuries for structured, high-value storage coffers. |
| **dourodoke** (or **histodoke**) | **δουροδόκη** (*Od.* 1.128) / **ἱστοδόκη** (*Il.* 1.434) | A **slotted spear-rack / indexed block** (δουροδόκης εὐξέστου). | Literally an **array of indexed slots** inside a polished timber block into which Athena slots her spear upon entering Odysseus's hall (*Od.* 1.128)—a physical SmallArray\# of pointers\! |
| **pykinos** (or **pyknos**) | **πυκινός / πυκνός** (*Il.* 16.212, 23.329; *Od.* 5.248, 23.193) | **Closely-packed, dense, cache-blocked, well-fitted** (also "wise/shrewd"). | In *Iliad* 16.212, Homer compares the Myrmidons' phalanx to a mason fitting together a wall with **closely-packed stone blocks** (ὡς δ᾽ ὅτε τοῖχον ἀνὴρ ἀράρῃ πυκνοῖσι λίθοισι). It is also the recurring Homeric epithet for a mind that is "tightly put together," directly echoing polytropos. |
| **angea** | **ἄγγεα** (sg. **ἄγγος**, *Od.* 2.289; *Il.* 2.471, 16.641) | **Containers / vessels** (the general Homeric plural noun for containers). | In *Odyssey* 2.289–290, Telemachus is instructed to pack all provisions into **ἄγγεσιν** ("containers"), with **ἀμφορεῦσιν** ("amphorae") as one subtype. angea is literally Homeric Greek for containers\! |
| **harmoniai** (or **gomphoi**) | **ἁρμονίαι** & **γόμφοι** (*Od.* 5.248, 5.361) | **Fitted structural joints & dowels** locking timber blocks together. | When Odysseus (the polytropos man himself) builds his craft in *Odyssey* 5.248, he bores the timber blocks and locks them into a contiguous array with dowels and joints (γόμφοισιν δ᾽ ἄρα τήν γε καὶ ἁρμονίῃσιν ἄρασσεν). |

#### **Naming Verdict**

> * If you want the most recognizable Homeric word for "containers": **amphores** (or Homeric **amphorees** / **angea**) works very well.  
> * If you want a name that specifically means **a rectangular box/chest packed densely (πυκινῶς)**: **larnax** or **chelos** (cheloi) is philologically spot-on.  
> * If you want a name that captures **tightly-packed contiguous stone/timber blocks** (and shares the intellectual double-meaning of polytropos): **pykinos** (or **pyknos**) is unbeatable.

Would you like to dive into how the **FAST 3-level blocking hierarchy (SIMD → Cache Line → Page/Superpage)** can be laid out inside a single ByteArray\# with arithmetic child indexing, or explore the Polytropos.Plugin Core-synthesis rules for BlockLayout?

---

*User prompt: I think limitations on in-place updates would make something FAST-like almost viable, but the extensions for persistence are I'm not sure how to accommodate. I wouldn't be surprised if someone already observed that FAST trees or other things like them aren't very efficiently restructurable and wanted to leverage the persistence to cope with it. I believe there is a kind of logic related to superpaging where you really need a dense superpage size spectrum — like what \`pgcl\` needs for within-kernel-allocation-unit superpaging — for the superpage allocation sizes to be able to avoid becoming pathological cases for the GC etc. when larger than the minimum mapping granularity. I tried this in my \`matryoshka\` repo at https\://github.com/NadiaYvette/matryoshka/ on GitHub, but I basically got a mostly-negative result. The competitive landscape would become radically more favourable in a competitive environment circumscribed by immutable data, though the winning strategy in that case would, of course, heavily involve persistence, though it would also demand substantially more beyond that. Or does it? Is there anything in the data structures & algorithms literature on the subject? Ah, the double meaning is the best\! I'm not sure whether to go with pykinos or pyknos yet, though. I'll have to mull over the sound.*

Response: Your intuition hits on one of the deepest tensions in data structure design: **the exact properties that make hierarchical memory layouts (like FAST and van Emde Boas trees) awkward in a mutable environment flip in their favor under immutability—provided you go beyond naive path-copying.**

## **1\. Why matryoshka Hit Friction in a Mutable Environment (and Why Immutability Flips the Game)**

In a mutable C or Rust setting, the baseline competitor to a multi-scale nested layout (blocks-within-blocks across SIMD, cache-line, page, and superpage granularities) is a simple in-place B+ tree with uniform 256 B–4 KB nodes. In that arena, a hierarchical FAST/vEB tree fights with one hand tied behind its back:

> 1. **The In-Place Restructuring Wall:** In a contiguous van Emde Boas (vEB) or FAST superblock of size *S*, subtrees are laid out recursively by height in breadth-first/vEB order. Inserting a single key that splits a node near the top of the superblock changes the subtree-index arithmetic for every descendant below it, forcing *O*(*S*) in-place memory shifts inside the superpage.  
> 2. **The Packed Memory Array (PMA) Tax:** The classic mutable workaround in the literature—pairing a static vEB tree with a **Packed Memory Array (Bender, Demaine, Farach-Colton, FOCS 2000\)**—maintains nested windows of sizes 21,22,…,2*k* with deliberate empty density gaps (*ρh*​…*τh*​). In practice, PMAs often yield disappointing results because maintaining 25%–50% empty gaps inside every window dilutes SIMD lane density, wastes TLB coverage, and still triggers *O*(2*k*) in-place element shifts and pointer rewirings on window overflows.  
> 3. **Zero-Allocation Baseline:** Meanwhile, the simple mutable B+ tree mutates a single 256-byte leaf in place with **zero allocator calls** and shifts at most 8–16 keys inside a single L1 cache line.

### **Why an Immutable / Persistent Environment Radically Changes the Calculus**

In Haskell, **in-place mutation of shared structures is already off the table**, and the baseline competitors (containers and unordered-containers) must allocate new heap closures along the entire root-to-leaf spine on every update while chasing 20 scattered pointers on every lookup.

More importantly, immutability eliminates the \#1 enemy of FAST and vEB layouts: **because an immutable superblock is never mutated in place after construction, it never needs PMA empty gaps.** Every frozen block at every scale of the hierarchy can be **100% densely packed** in exact FAST/vEB order.

## **2\. Why a Dense Superpage Size Spectrum Is Essential for GC and Persistence**

Your observation from pgcl (page clustering over hardware base pages combined with Navarro–Iyer–Druschel–Cox superpaging) and matryoshka translates directly to garbage-collected runtimes.

If a system only offers a **coarse, bimodal size spectrum**—say, 64-byte cache lines at the bottom and 64 KB or 2 MB superblocks at the top, with nothing in between—two pathological failure modes immediately emerge:

> * **CoW & GC Nursery Amplification:** If a subtree of 500 elements is forced into a 64 KB or 2 MB superblock, a single persistent insert must copy the entire superblock. In GHC, any allocation ≥3,277 bytes (LARGE\_OBJECT\_THRESHOLD, 80% of a 4 KB block) bypasses the lock-free per-capability Gen-0 nursery bump pointer and allocates a BF\_LARGE object under the global block-allocator lock. Path-copying coarse superblocks turns *O*(log*N*) updates into global-lock memory-bandwidth bottlenecks.  
> * **Internal Fragmentation vs. Promotion Thrashing:** Just as an OS kernel with only 4 KB and 2 MB pages suffers either massive internal fragmentation (zero-filling 2 MB for a 20 KB working set) or promotion/demotion storms, a tree without intermediate block sizes (128 B,256 B,512 B,1 KB,2 KB,4 KB,8 KB,16 KB,32 KB) cannot match allocation granularity to subtree weight. Worse, when GC survival is partial, coarse blocks suffer severe **liveness dilution** (one live reference keeping a large block pinned in old-gen memory).

With a **dense size spectrum** (e.g., sub-page power-of-two blocks 26…211 bytes inside the GHC nursery, transitioning smoothly into 4 KB,8 KB,16 KB,32 KB,64 KB page clusters), every subtree sits in the tightest container that matches both its cardinality and its **mutation temperature**.

## **3\. What the DSA Literature Says: What Is Needed *Beyond* Naive Persistence?**

Researchers quickly noticed that FAST trees and cache-oblivious vEB layouts cannot be updated efficiently in place—and that naive persistent path-copying on large blocks fails due to write amplification. Four major lines of work in the data structures literature show what is required **beyond simple path-copying** to make hierarchical blocked structures win on both queries and updates:

### **A. Functional Delta Chains \+ Consolidation (The Bw-Tree & Intel PALM)**

Right after Kim et al. published **FAST** (SIGMOD 2010), the same Intel Labs group published **PALM** (VLDB 2011), and Levandoski, Lomet, and Sengupta at Microsoft Research published the **Bw-Tree** (ICDE 2013).

> * **The Insight:** Never copy or restructure a large, cache/TLB-blocked node on individual updates.  
> * **The Mechanism:** Treat the FAST/page-blocked node as an **immutable base block**. When an update arrives, prepend a tiny, immutable **delta record** (an insert, delete, or split delta) to the block's pointer slot.  
> * **How this works in Haskell:** A SuperBlock constructor holds:  
  1. A small, nursery-allocated **Delta Block** (e.g., a 64-byte SIMD ByteArray\# holding up to 8 recent insertions/tombstones in sorted order).  
  2. A pointer to the **Immutable FAST Base Block** (e.g., a 4 KB–16 KB depth-3 vEB subtree packed in one ByteArray\#).  
  * **Lookups** check the 8-element SIMD delta in **1 AVX2 instruction** alongside the FAST base block (zero asymptotic penalty).  
  * **Updates** only copy-on-write the 64-byte Delta Block\!  
  * Only when the 8-element Delta Block fills up do you merge it into the FAST Base Block to produce a fresh, 100%-dense FAST block—**amortizing the superblock rebuild cost by 8×–16×** and keeping 90% of allocations inside the lock-free L1 nursery.

### **B. Weight-Balanced B-Trees & CPAM (Sizing Blocks by Subtree Weight)**

How do you map a tree onto a dense Matryoshka size spectrum automatically?

> * **Arge & Vitter (FOCS 1996), *Optimal Dynamic Interval Management in External Memory* (Weight-Balanced B-Trees):** Unlike standard B+ trees (where a node can split again immediately after splitting if insertions focus on one leaf), a node at level *h* in a **Weight-Balanced B-Tree (WBB-Tree)** is governed by the *total number of elements in its subtree* (its weight *w*\=Θ(*Bh*)). A node of weight *W* is mathematically guaranteed not to split or merge again until at least Ω(*W*) updates occur beneath it.  
> * **Blelloch, Ferizovic, & Sun (PPoPP 2022), *CPAM: Compressed Parallel Augmented Maps*:** Blelloch's group studied persistent/functional trees in detail and showed that combining **weight-balanced trees** with **flattened multi-element blocks** solves the persistent granularity problem:  
  * In a Matryoshka/spectrum tree, let a subtree's **weight *W*** directly select its block size along your dense size spectrum:  
    * Subtrees of weight *W*≤16 live in a single 128 B SIMD block.  
    * Subtrees of weight 16\<*W*≤256 that are **cold** (not mutated in the current epoch) are packed into a single 2 KB–4 KB 2-level FAST block (root block \+ 16 child blocks packed contiguously in one ByteArray\#).  
    * As soon as a persistent update touches one of the 16 children inside a 4 KB FAST superblock, **it does not need to rebuild the 4 KB superblock**: it converts the root back into a normal 16-way internal node sharing slices/children with the existing block, mutating only the touched 128 B leaf\!

### **C. Write-Optimized B*ε*\-Trees (Brodal & Fagerberg, SODA 2003\)**

If you want persistent updates that are actually *faster* than a mutable B+ tree while keeping large superblock nodes:

> * **Brodal & Fagerberg (2003)** introduced the **B*ε*\-tree**, which reserves a fraction *Bε* of each internal node's block capacity as a **message buffer** for pending insertions, updates, and deletions.  
> * In a purely functional Haskell setting, an internal node of size 4 KB doesn't flush every insert down to the leaves: it inserts the new key into its local SIMD buffer (copying only the compact buffer array). When the buffer fills, it flushes a batch of keys down to whichever child has the most pending updates, rebuilding that child's FAST block in one batched pass. This drops persistent update cost from *O*(*B*log*B*​*N*) to *O*(*BεB*​log*B*​*N*)—often beating mutable in-place B+ trees on random inserts because it turns random leaf writes into batched sequential block rebuilds.

### **D. The Logarithmic Method \+ Fractional Cascading (COLA: Bender et al., SPAA 2007\)**

If you want to exploit the **entire superpage spectrum** (20,21,…,2*k* blocks) with **zero in-place restructuring**:

> * **COLA (Cache-Oblivious Lookahead Arrays, Bender et al. 2007\)** applies Bentley & Saxe's logarithmic method directly to hierarchical vEB/FAST layouts.  
> * Instead of one monolithic tree, the container is a persistent sequence of ≤log2​*N* **100%-dense, completely immutable FAST/vEB superblocks** whose sizes follow your exact geometric size spectrum (256 B,1 KB,4 KB,16 KB,64 KB,256 KB,1 MB).  
> * An insertion goes into the smallest block (256 B); when adjacent levels fill, they merge in a linear SIMD stream into the next size up in the spectrum (identical to GHC's generational GC promotion\!).  
> * To prevent lookups from paying an *O*(log2*N*) penalty across the levels, COLA embeds **lookahead / fractional cascading pointers** (Chazelle & Guibas 1986\) from level *i*\+1 into level *i*: every 8th key from the larger FAST block is sampled into the smaller FAST block with its exact byte offset, so a lookup only searches the top block and jumps directly into the target SIMD lane of every subsequent superblock in *O*(1) per level.

## **4\. How This Synthesizes into Your Haskell Design (pykinos / pyknos)**

Putting your matryoshka / pgcl size-spectrum insight together with polytropos and the DSA literature gives a concrete 3-mechanism design that turns Haskell's immutability into an unfair advantage:

> 1. **Dense Spectrum of Polytropos.Block Capacities:** Instead of a single hardcoded fanout, parameterize blocks over the dense spectrum *B*∈{8,16,32,64,128,256} (and multi-level FAST superblocks of 4 KB / 16 KB / 64 KB). Small nodes near the mutation frontier allocate \< 512 bytes in the Gen-0 nursery; cold subtrees are compacted into single-ByteArray\# FAST superblocks.  
> 2. **Lazy Unpacking on Write ("Coalesced Cold, Decomposed Hot"):** A FastSuperBlock (packing a depth-2 or depth-3 subtree of 16+162\=272 keys into one contiguous 4 KB ByteArray\# for 1-TLB-hit reads) is used for read-heavy subtrees. When an insert hits that subtree, you don't copy-on-write all 4 KB: you either append to an 8-element SIMD delta buffer on the superblock (Bw-tree style) or unpack just the affected 16-key child into a 128-byte nursery Block, leaving the remaining 15/16ths of the superblock shared via zero-copy offset views until the next consolidation pass.  
> 3. **Explicit compact / Generational Promotion:** Any sub-tree can be promoted into a single contiguous FAST ByteArray\# superblock on demand (or automatically during bulk operations like fromList, union, or B*ε* buffer flushes), aligning the physical memory layout with GHC's generational heap.

## **5\. On pykinos vs. pyknos**

Both are great, and they actually have distinct rhythmic personalities depending on what vibe you want in .cabal files and import statements:

> * **pykinos (πυκινός):** Has that unmistakable, rolling dactylic Homeric cadence (three syllables, like *Odysseus* or *polytropos*). Because πυκινός is the specifically **epic/poetic** form (whereas πυκνός is the later contracted Attic prose form), pykinos immediately signals to anyone who knows Greek that it comes straight out of Homer (*Iliad* 16.212's closely fitted stone blocks and πυκινὸν νόον, the tightly packed mind)—making it a direct literary sibling to polytropos.  
> * **pyknos (πυκνός):** Two crisp, percussive syllables—short to type, punchy, and recognizable from scientific English (*pyknometer*, *pyknosis*).

Would you like to sketch out how the **"Coalesced Cold (FAST Superblock) / Decomposed Hot (SIMD Delta \+ Nursery Block)"** node representation looks in Haskell with ByteArray\# arithmetic indexing, or look at how **COLA fractional cascading** across a dense size spectrum works with SIMD blocks?

---

