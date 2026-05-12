## BL808 Kernel Heap Allocator
##
## Wraps the TLSF (Two-Level Segregated Fit) C allocator.
## Provides O(1) malloc/free with bounded fragmentation.
##
## The TLSF C implementation exports malloc/free/realloc/calloc symbols
## that Nim's mm:arc + useMalloc uses automatically.
##
## This module provides the init call and stats API.

# Compile C sources alongside this module
{.compile: "tlsf.c".}
{.compile: "baremetal_libc.c".}

# =============================================================================
# External symbols from linker script
# =============================================================================
{.emit: """
extern unsigned long _sheap;
extern unsigned long _eheap;
extern void tlsf_init(void *heap_start, void *heap_end);
extern unsigned long tlsf_get_used(void);
extern unsigned long tlsf_get_total(void);
extern unsigned long tlsf_get_alloc_count(void);
extern unsigned long tlsf_get_free_count(void);
extern unsigned long tlsf_get_high_water(void);
extern unsigned long tlsf_get_min_free(void);
extern unsigned long tlsf_get_largest_free(void);
extern unsigned long tlsf_get_alloc_fail_count(void);
extern unsigned long tlsf_get_invalid_free_count(void);
extern unsigned long tlsf_get_canary_fail_count(void);
extern int tlsf_check_heap(void);
""".}

# =============================================================================
# TLSF C API bindings
# =============================================================================
proc tlsfInit(heapStart: pointer, heapEnd: pointer) {.importc: "tlsf_init", nodecl.}
proc tlsfGetUsed*(): csize_t {.importc: "tlsf_get_used", nodecl.}
proc tlsfGetTotal*(): csize_t {.importc: "tlsf_get_total", nodecl.}
proc tlsfGetAllocCount*(): csize_t {.importc: "tlsf_get_alloc_count", nodecl.}
proc tlsfGetFreeCount*(): csize_t {.importc: "tlsf_get_free_count", nodecl.}
proc tlsfGetHighWater*(): csize_t {.importc: "tlsf_get_high_water", nodecl.}
proc tlsfGetMinFree*(): csize_t {.importc: "tlsf_get_min_free", nodecl.}
proc tlsfGetLargestFree*(): csize_t {.importc: "tlsf_get_largest_free", nodecl.}
proc tlsfGetAllocFailCount*(): csize_t {.importc: "tlsf_get_alloc_fail_count", nodecl.}
proc tlsfGetInvalidFreeCount*(): csize_t {.importc: "tlsf_get_invalid_free_count", nodecl.}
proc tlsfGetCanaryFailCount*(): csize_t {.importc: "tlsf_get_canary_fail_count", nodecl.}
proc tlsfCheckHeapRaw(): cint {.importc: "tlsf_check_heap", nodecl.}

# =============================================================================
# Initialization
# =============================================================================
proc heapInit*() =
  ## Initialize the TLSF heap allocator using the linker-script heap region.
  ## Must be called before any ref allocations (i.e., before any CPS code).
  {.emit: """
  tlsf_init((void *)&_sheap, (void *)&_eheap);
  """.}

# =============================================================================
# Stats
# =============================================================================
type
  HeapStats* = object
    usedBytes*: uint
    totalBytes*: uint
    allocCount*: uint
    freeCount*: uint
    freeBytes*: uint
    highWaterBytes*: uint
    minFreeBytes*: uint
    largestFreeBytes*: uint
    allocFailCount*: uint
    invalidFreeCount*: uint
    canaryFailCount*: uint

proc heapStats*(): HeapStats =
  let used = tlsfGetUsed().uint
  let total = tlsfGetTotal().uint
  HeapStats(
    usedBytes: used,
    totalBytes: total,
    allocCount: tlsfGetAllocCount().uint,
    freeCount: tlsfGetFreeCount().uint,
    freeBytes: total - used,
    highWaterBytes: tlsfGetHighWater().uint,
    minFreeBytes: tlsfGetMinFree().uint,
    largestFreeBytes: tlsfGetLargestFree().uint,
    allocFailCount: tlsfGetAllocFailCount().uint,
    invalidFreeCount: tlsfGetInvalidFreeCount().uint,
    canaryFailCount: tlsfGetCanaryFailCount().uint,
  )

proc heapCheck*(): bool =
  ## Walk heap metadata and allocation canaries.
  tlsfCheckHeapRaw() != 0
