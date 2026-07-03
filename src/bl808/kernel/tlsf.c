/*
 * Minimal TLSF (Two-Level Segregated Fit) allocator for bare-metal RTOS.
 *
 * O(1) malloc/free with bounded fragmentation.
 * Based on the TLSF algorithm by M. Masmano et al.
 *
 * This is a simplified single-pool implementation suitable for embedded use.
 * Public domain.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Use-after-free detection: poison freed payloads with 0xDEAD1EEF. OFF by
   default (bus-stalls on a wild deref; diagnostic only). -DTLSF_POISON_FREED. */

/* ========================================================================= */
/* Configuration                                                              */
/* ========================================================================= */

/* First-level index: log2 of max block size. 20 = 1MB max block. */
#define FL_INDEX_MAX    20
/* Second-level index: subdivision bits per first-level. */
#define SL_INDEX_LOG2   4
#define SL_INDEX_COUNT  (1 << SL_INDEX_LOG2)

/* Minimum block size (must be >= sizeof(block_header_t) + alignment) */
#define BLOCK_SIZE_MIN  32
#define BLOCK_ALIGN     8

/* Block header overhead */
#define ALIGN_UP(x, a)  (((x) + ((a) - 1)) & ~((a) - 1))
#define BLOCK_OVERHEAD  ALIGN_UP(sizeof(block_header_t), BLOCK_ALIGN)

#define BLOCK_MAGIC_USED 0xC0FFEE01u
#define BLOCK_MAGIC_FREE 0xFEEEFEEDu
#define BLOCK_TAIL_CANARY 0xBAADF00Du
#define BLOCK_CANARY_SIZE 4

/* ========================================================================= */
/* Block header                                                               */
/* ========================================================================= */

typedef struct block_header {
    /* Size of the data area (excludes header). Low bits used as flags:
       bit 0: 1 = block is free
       bit 1: 1 = previous physical block is free */
    size_t size;
    /* Previous physical block (only valid when prev_phys is free) */
    struct block_header *prev_phys;
    /* Free list links (only valid when block is free) */
    struct block_header *next_free;
    struct block_header *prev_free;
    /* Requested user size, excluding allocator guard bytes. */
    size_t requested_size;
    /* Call site that allocated this block (from the malloc/calloc/realloc
       wrappers) — lets canary/invalid-free forensics name the owner. */
    uintptr_t alloc_site;
    uint32_t magic;
} block_header_t;

#define BLOCK_FREE_BIT      ((size_t)1)
#define BLOCK_PREV_FREE_BIT ((size_t)2)
#define BLOCK_FLAG_BITS     (BLOCK_FREE_BIT | BLOCK_PREV_FREE_BIT)

static inline size_t block_size(const block_header_t *b) {
    return b->size & ~BLOCK_FLAG_BITS;
}

static inline int block_is_free(const block_header_t *b) {
    return (b->size & BLOCK_FREE_BIT) != 0;
}

static inline int block_prev_is_free(const block_header_t *b) {
    return (b->size & BLOCK_PREV_FREE_BIT) != 0;
}

static inline void block_set_size(block_header_t *b, size_t s) {
    b->size = s | (b->size & BLOCK_FLAG_BITS);
}

static inline void block_set_free(block_header_t *b) {
    b->size |= BLOCK_FREE_BIT;
}

static inline void block_set_used(block_header_t *b) {
    b->size &= ~BLOCK_FREE_BIT;
}

static inline void block_set_prev_free(block_header_t *b) {
    b->size |= BLOCK_PREV_FREE_BIT;
}

static inline void block_set_prev_used(block_header_t *b) {
    b->size &= ~BLOCK_PREV_FREE_BIT;
}

static inline block_header_t *block_next(block_header_t *b) {
    return (block_header_t *)((uint8_t *)b + BLOCK_OVERHEAD + block_size(b));
}

static inline void *block_to_ptr(block_header_t *b) {
    return (void *)((uint8_t *)b + BLOCK_OVERHEAD);
}

static inline block_header_t *ptr_to_block(void *p) {
    return (block_header_t *)((uint8_t *)p - BLOCK_OVERHEAD);
}

/* ========================================================================= */
/* TLSF control structure                                                     */
/* ========================================================================= */

typedef struct {
    /* Bitmaps for O(1) free list lookup */
    uint32_t fl_bitmap;
    uint32_t sl_bitmap[FL_INDEX_MAX];
    /* Segregated free lists */
    block_header_t *blocks[FL_INDEX_MAX][SL_INDEX_COUNT];
    /* Pool bounds for validation */
    void *pool_start;
    void *pool_end;
    /* Stats */
    size_t used_bytes;
    size_t total_bytes;
    size_t alloc_count;
    size_t free_count;
    size_t high_water_bytes;
    size_t min_free_bytes;
    size_t alloc_fail_count;
    size_t invalid_free_count;
    size_t canary_fail_count;
    /* Forensics: fingerprint WHO damages blocks. The caller of the failing
       free and the damaged block's requested size identify the owning
       subsystem without a debugger attached. */
    uintptr_t last_invalid_free_ptr;
    uintptr_t last_invalid_free_caller;
    size_t last_canary_fail_size;
    uintptr_t last_canary_fail_caller;
    uintptr_t last_canary_fail_alloc_site;
    /* First 3 words of the damaged block's payload: for WiFi ke_msg blocks
       this is the message header (next, id|dst|src, paramLen) — names the
       message type without symbols. */
    uint32_t last_canary_fail_data[3];
    /* The 4 bytes found where the tail canary should be = the value the
       overrunning writer stored. Usually names the writer directly. */
    uint32_t last_canary_fail_overwrite;
    uintptr_t last_canary_fail_ptr;
    uintptr_t last_double_free_alloc_site;
    size_t double_free_count;
} tlsf_t;

static tlsf_t tlsf_pool;

/* Recent-frees ring: names the ke_msg type on a later double-free. */
#define RECENT_FREE_RING 64
static struct { uintptr_t ptr; uint32_t hdr_id; } recent_free_ring[RECENT_FREE_RING];
static unsigned recent_free_idx;
static uint32_t last_double_free_msg;

extern uintptr_t tlsf_last_free_site;   /* set by the free()/realloc() wrappers */
extern uintptr_t tlsf_last_alloc_site;  /* set by the malloc/calloc/realloc wrappers */

static inline int ptr_in_pool(const void *p) {
    return p >= tlsf_pool.pool_start && p < tlsf_pool.pool_end;
}

static inline size_t accounted_block_size(const block_header_t *b) {
    return block_size(b) + BLOCK_OVERHEAD;
}

static void update_watermarks(void) {
    if (tlsf_pool.used_bytes > tlsf_pool.high_water_bytes) {
        tlsf_pool.high_water_bytes = tlsf_pool.used_bytes;
    }
    size_t free_bytes = 0;
    if (tlsf_pool.total_bytes >= tlsf_pool.used_bytes) {
        free_bytes = tlsf_pool.total_bytes - tlsf_pool.used_bytes;
    }
    if (free_bytes < tlsf_pool.min_free_bytes) {
        tlsf_pool.min_free_bytes = free_bytes;
    }
}

static int size_with_canary(size_t requested, size_t *out) {
    if (requested > ((size_t)-1) - BLOCK_CANARY_SIZE) {
        return 0;
    }
    size_t internal = requested + BLOCK_CANARY_SIZE;
    internal = ALIGN_UP(internal, BLOCK_ALIGN);
    if (internal < BLOCK_SIZE_MIN) {
        internal = BLOCK_SIZE_MIN;
    }
    *out = internal;
    return 1;
}

static void write_tail_canary(block_header_t *b) {
    if (b->requested_size + BLOCK_CANARY_SIZE > block_size(b)) {
        return;
    }
    uint8_t *p = (uint8_t *)block_to_ptr(b) + b->requested_size;
    uint32_t v = BLOCK_TAIL_CANARY;
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)((v >> 8) & 0xff);
    p[2] = (uint8_t)((v >> 16) & 0xff);
    p[3] = (uint8_t)((v >> 24) & 0xff);
}

static int tail_canary_ok(const block_header_t *b) {
    if (b->requested_size + BLOCK_CANARY_SIZE > block_size(b)) {
        return 0;
    }
    const uint8_t *p = (const uint8_t *)block_to_ptr((block_header_t *)b) + b->requested_size;
    uint32_t v = ((uint32_t)p[0]) |
                 ((uint32_t)p[1] << 8) |
                 ((uint32_t)p[2] << 16) |
                 ((uint32_t)p[3] << 24);
    return v == BLOCK_TAIL_CANARY;
}

static int block_header_valid(block_header_t *b) {
    if (!ptr_in_pool(b)) return 0;
    if (((uintptr_t)b & (BLOCK_ALIGN - 1)) != 0) return 0;
    size_t size = block_size(b);
    if (size < BLOCK_SIZE_MIN) return 0;
    if ((uint8_t *)b + BLOCK_OVERHEAD + size > (uint8_t *)tlsf_pool.pool_end) {
        return 0;
    }
    if (b->magic != BLOCK_MAGIC_USED && b->magic != BLOCK_MAGIC_FREE) {
        return 0;
    }
    return 1;
}

/* ========================================================================= */
/* Bit manipulation                                                           */
/* ========================================================================= */

static inline int tlsf_fls(uint32_t x) {
    /* Find last set bit (0-indexed). Returns -1 for 0. */
    if (x == 0) return -1;
    return 31 - __builtin_clz(x);
}

static inline int tlsf_ffs(uint32_t x) {
    /* Find first set bit (0-indexed). Returns -1 for 0. */
    if (x == 0) return -1;
    return __builtin_ctz(x);
}

/* ========================================================================= */
/* Mapping: size -> (fl, sl) indices                                          */
/* ========================================================================= */

static void mapping_insert(size_t size, int *fl, int *sl) {
    if (size < BLOCK_SIZE_MIN) {
        *fl = 0;
        *sl = (int)(size / (BLOCK_SIZE_MIN / SL_INDEX_COUNT));
    } else {
        *fl = tlsf_fls((uint32_t)size);
        *sl = (int)((size >> (*fl - SL_INDEX_LOG2)) ^ SL_INDEX_COUNT);
        /* Adjust fl to be relative to BLOCK_SIZE_MIN */
    }
}

static void mapping_search(size_t size, int *fl, int *sl) {
    /* Round up to next block boundary for search */
    if (size >= BLOCK_SIZE_MIN) {
        size_t round = (1 << (tlsf_fls((uint32_t)size) - SL_INDEX_LOG2)) - 1;
        size += round;
    }
    mapping_insert(size, fl, sl);
}

/* ========================================================================= */
/* Free list operations                                                       */
/* ========================================================================= */

static void insert_free_block(block_header_t *block) {
    int fl, sl;
    size_t size = block_size(block);
    mapping_insert(size, &fl, &sl);

    if (fl >= FL_INDEX_MAX) fl = FL_INDEX_MAX - 1;
    if (sl >= SL_INDEX_COUNT) sl = SL_INDEX_COUNT - 1;

    block_header_t *head = tlsf_pool.blocks[fl][sl];
    block->next_free = head;
    block->prev_free = NULL;
    if (head) {
        head->prev_free = block;
    }
    tlsf_pool.blocks[fl][sl] = block;

    tlsf_pool.fl_bitmap |= (1U << fl);
    tlsf_pool.sl_bitmap[fl] |= (1U << sl);
}

static void remove_free_block(block_header_t *block) {
    int fl, sl;
    mapping_insert(block_size(block), &fl, &sl);

    if (fl >= FL_INDEX_MAX) fl = FL_INDEX_MAX - 1;
    if (sl >= SL_INDEX_COUNT) sl = SL_INDEX_COUNT - 1;

    if (block->prev_free) {
        block->prev_free->next_free = block->next_free;
    } else {
        tlsf_pool.blocks[fl][sl] = block->next_free;
    }
    if (block->next_free) {
        block->next_free->prev_free = block->prev_free;
    }

    /* Update bitmaps if list is now empty */
    if (tlsf_pool.blocks[fl][sl] == NULL) {
        tlsf_pool.sl_bitmap[fl] &= ~(1U << sl);
        if (tlsf_pool.sl_bitmap[fl] == 0) {
            tlsf_pool.fl_bitmap &= ~(1U << fl);
        }
    }
}

/* ========================================================================= */
/* Block splitting and merging                                                */
/* ========================================================================= */

static block_header_t *split_block(block_header_t *block, size_t size) {
    size_t current = block_size(block);
    if (current < size + BLOCK_OVERHEAD + BLOCK_SIZE_MIN) {
        return NULL;  /* Too small to split */
    }

    size_t remain = current - size - BLOCK_OVERHEAD;
    if (remain < BLOCK_SIZE_MIN) {
        return NULL;  /* Too small to split */
    }

    block_header_t *rest = (block_header_t *)((uint8_t *)block + BLOCK_OVERHEAD + size);
    rest->size = 0;
    block_set_size(rest, remain);
    block_set_free(rest);
    block_set_prev_used(rest);  /* The allocated block before it is used */
    rest->prev_phys = block;
    rest->requested_size = 0;
    rest->magic = BLOCK_MAGIC_FREE;

    block_set_size(block, size);

    /* Update next block's prev_phys pointer */
    block_header_t *next = block_next(rest);
    if ((void *)next < tlsf_pool.pool_end) {
        next->prev_phys = rest;
        block_set_prev_free(next);
    }

    return rest;
}

static block_header_t *merge_prev(block_header_t *block) {
    if (block_prev_is_free(block)) {
        block_header_t *prev = block->prev_phys;
        remove_free_block(prev);
        size_t new_size = block_size(prev) + BLOCK_OVERHEAD + block_size(block);
        block_set_size(prev, new_size);
        /* Update next block's prev_phys */
        block_header_t *next = block_next(prev);
        if ((void *)next < tlsf_pool.pool_end) {
            next->prev_phys = prev;
        }
        return prev;
    }
    return block;
}

static block_header_t *merge_next(block_header_t *block) {
    block_header_t *next = block_next(block);
    if ((void *)next < tlsf_pool.pool_end && block_is_free(next)) {
        remove_free_block(next);
        size_t new_size = block_size(block) + BLOCK_OVERHEAD + block_size(next);
        block_set_size(block, new_size);
        /* Update the block after next's prev_phys */
        block_header_t *nn = block_next(block);
        if ((void *)nn < tlsf_pool.pool_end) {
            nn->prev_phys = block;
        }
    }
    return block;
}

/* ========================================================================= */
/* Find a suitable free block                                                 */
/* ========================================================================= */

static block_header_t *find_suitable_block(size_t size) {
    int fl, sl;
    mapping_search(size, &fl, &sl);

    if (fl >= FL_INDEX_MAX) return NULL;

    /* Search in current sl bitmap first */
    uint32_t sl_map = tlsf_pool.sl_bitmap[fl] & (~0U << sl);
    if (sl_map == 0) {
        /* No block at this fl level, search higher fl */
        uint32_t fl_map = tlsf_pool.fl_bitmap & (~0U << (fl + 1));
        if (fl_map == 0) return NULL;  /* No suitable block */
        fl = tlsf_ffs(fl_map);
        sl_map = tlsf_pool.sl_bitmap[fl];
    }
    sl = tlsf_ffs(sl_map);

    return tlsf_pool.blocks[fl][sl];
}

/* ========================================================================= */
/* Public API                                                                 */
/* ========================================================================= */

void tlsf_init(void *heap_start, void *heap_end) {
    /* Align start up and end down */
    uintptr_t start = ((uintptr_t)heap_start + BLOCK_ALIGN - 1) & ~(BLOCK_ALIGN - 1);
    uintptr_t end = (uintptr_t)heap_end & ~(BLOCK_ALIGN - 1);
    size_t pool_size = end - start;

    memset(&tlsf_pool, 0, sizeof(tlsf_pool));
    tlsf_pool.pool_start = (void *)start;
    tlsf_pool.pool_end = (void *)end;
    tlsf_pool.total_bytes = pool_size;
    tlsf_pool.min_free_bytes = pool_size;

    if (pool_size < BLOCK_SIZE_MIN + BLOCK_OVERHEAD * 2) {
        return;  /* Pool too small */
    }

    /* Create one large free block spanning the entire pool */
    block_header_t *block = (block_header_t *)start;
    size_t block_data_size = pool_size - BLOCK_OVERHEAD;
    /* Ensure alignment */
    block_data_size &= ~(BLOCK_ALIGN - 1);

    block->size = 0;
    block_set_size(block, block_data_size);
    block_set_free(block);
    block_set_prev_used(block);  /* No previous block */
    block->prev_phys = NULL;
    block->requested_size = 0;
    block->magic = BLOCK_MAGIC_FREE;

    insert_free_block(block);
}

void *tlsf_malloc(size_t size) {
    if (size == 0) return NULL;
    size_t requested = size;

    if (!size_with_canary(requested, &size)) {
        tlsf_pool.alloc_fail_count++;
        return NULL;
    }

    block_header_t *block = find_suitable_block(size);
    if (block == NULL) {
        tlsf_pool.alloc_fail_count++;
        return NULL;
    }

    remove_free_block(block);

    /* Split if possible */
    block_header_t *remain = split_block(block, size);
    if (remain) {
        insert_free_block(remain);
    }

    block_set_used(block);
    block->requested_size = requested;
    block->magic = BLOCK_MAGIC_USED;
    write_tail_canary(block);
    block->alloc_site = tlsf_last_alloc_site;

    /* Mark next block's prev as used */
    block_header_t *next = block_next(block);
    if ((void *)next < tlsf_pool.pool_end) {
        block_set_prev_used(next);
    }

    tlsf_pool.used_bytes += accounted_block_size(block);
    tlsf_pool.alloc_count++;
    update_watermarks();

    return block_to_ptr(block);
}

void tlsf_free(void *ptr) {
    if (ptr == NULL) return;

    block_header_t *block = ptr_to_block(ptr);
    if (!block_header_valid(block) || block->magic != BLOCK_MAGIC_USED ||
        block_is_free(block)) {
        tlsf_pool.invalid_free_count++;
        tlsf_pool.last_invalid_free_ptr = (uintptr_t)ptr;
        tlsf_pool.last_invalid_free_caller = tlsf_last_free_site;
        /* Double-free forensics: if this is a free of an in-pool block that is
           already FREE (a genuine double-free, not a wild pointer), the header
           still holds the ORIGINAL alloc_site — records WHAT object type is
           being double-freed even though the freeing caller is tail-obscured. */
        if (ptr_in_pool(block) && block->magic == BLOCK_MAGIC_FREE) {
            tlsf_pool.last_double_free_alloc_site = block->alloc_site;
            tlsf_pool.double_free_count++;
            for (unsigned i = 0; i < RECENT_FREE_RING; i++) {
                if (recent_free_ring[i].ptr == (uintptr_t)ptr) {
                    last_double_free_msg = recent_free_ring[i].hdr_id;
                    break;
                }
            }
        }
        return;
    }
    if (!tail_canary_ok(block)) {
        tlsf_pool.canary_fail_count++;
        tlsf_pool.last_canary_fail_size = block->requested_size;
        tlsf_pool.last_canary_fail_caller = tlsf_last_free_site;
        tlsf_pool.last_canary_fail_alloc_site = block->alloc_site;
        {
            const uint32_t *w = (const uint32_t *)ptr;
            tlsf_pool.last_canary_fail_data[0] = w[0];
            tlsf_pool.last_canary_fail_data[1] = w[1];
            tlsf_pool.last_canary_fail_data[2] = w[2];
            const uint8_t *c = (const uint8_t *)ptr + block->requested_size;
            tlsf_pool.last_canary_fail_overwrite =
                ((uint32_t)c[0]) | ((uint32_t)c[1] << 8) |
                ((uint32_t)c[2] << 16) | ((uint32_t)c[3] << 24);
            tlsf_pool.last_canary_fail_ptr = (uintptr_t)ptr;
        }
    }

    /* Record this (about-to-be-freed) block's second payload word — for a
       WiFi ke_msg that's the {id|dst<<16|src<<24} header — in a small ring
       keyed by pointer. A later double-free of the same pointer looks it up to
       name the message type, even though the freed block's contents are gone. */
    {
        recent_free_ring[recent_free_idx].ptr = (uintptr_t)ptr;
        recent_free_ring[recent_free_idx].hdr_id = ((const uint32_t *)ptr)[1];
        recent_free_idx = (recent_free_idx + 1) & (RECENT_FREE_RING - 1);
    }

    tlsf_pool.used_bytes -= accounted_block_size(block);
    tlsf_pool.free_count++;

#ifdef TLSF_POISON_FREED
    /* Poison the freed payload so a use-after-free reads an obviously-bad,
       word-aligned pointer (0xDEAD1EEF) rather than stale/plausible data. A
       stale reader then faults immediately AT the read (mepc = the reader)
       instead of much later, and a poisoned string pointer is unmistakable in
       a crash dump. Skip the block header words we still need. */
    {
        size_t payload_words = block_size(block) / 4;
        uint32_t *pw = (uint32_t *)block_to_ptr(block);
        for (size_t i = 0; i + 1 < payload_words; i++) pw[i] = 0xDEAD1EEFu;
    }
#endif

    block_set_free(block);
    block->requested_size = 0;
    block->magic = BLOCK_MAGIC_FREE;

    /* Merge with adjacent free blocks */
    block = merge_prev(block);
    block = merge_next(block);

    insert_free_block(block);

    /* Mark next block's prev as free */
    block_header_t *next = block_next(block);
    if ((void *)next < tlsf_pool.pool_end) {
        next->prev_phys = block;
        block_set_prev_free(next);
    }
}

void *tlsf_realloc(void *ptr, size_t new_size) {
    if (ptr == NULL) return tlsf_malloc(new_size);
    if (new_size == 0) {
        tlsf_free(ptr);
        return NULL;
    }

    size_t requested = new_size;
    if (!size_with_canary(requested, &new_size)) {
        tlsf_pool.alloc_fail_count++;
        return NULL;
    }

    block_header_t *block = ptr_to_block(ptr);
    if (!block_header_valid(block) || block->magic != BLOCK_MAGIC_USED ||
        block_is_free(block)) {
        tlsf_pool.invalid_free_count++;
        return NULL;
    }
    if (!tail_canary_ok(block)) {
        tlsf_pool.canary_fail_count++;
        return NULL;
    }
    size_t cur_size = block_size(block);
    size_t old_accounted = accounted_block_size(block);
    size_t old_requested = block->requested_size;

    if (cur_size >= new_size) {
        /* Shrink: optionally split */
        block_header_t *remain = split_block(block, new_size);
        if (remain) {
            block_set_free(remain);
            remain = merge_next(remain);
            insert_free_block(remain);
            block_header_t *nn = block_next(remain);
            if ((void *)nn < tlsf_pool.pool_end) {
                nn->prev_phys = remain;
                block_set_prev_free(nn);
            }
        }
        block->requested_size = requested;
        block->magic = BLOCK_MAGIC_USED;
        write_tail_canary(block);
    block->alloc_site = tlsf_last_alloc_site;
        size_t new_accounted = accounted_block_size(block);
        if (old_accounted >= new_accounted) {
            tlsf_pool.used_bytes -= old_accounted - new_accounted;
        }
        return ptr;
    }

    /* Try to expand into next block */
    block_header_t *next = block_next(block);
    if ((void *)next < tlsf_pool.pool_end && block_is_free(next)) {
        size_t combined = cur_size + BLOCK_OVERHEAD + block_size(next);
        if (combined >= new_size) {
            remove_free_block(next);
            block_set_size(block, combined);
            block_header_t *remain = split_block(block, new_size);
            if (remain) {
                insert_free_block(remain);
            }
            block_header_t *nn = block_next(block);
            if ((void *)nn < tlsf_pool.pool_end) {
                nn->prev_phys = block;
                block_set_prev_used(nn);
            }
            block->requested_size = requested;
            block->magic = BLOCK_MAGIC_USED;
            write_tail_canary(block);
    block->alloc_site = tlsf_last_alloc_site;
            size_t new_accounted = accounted_block_size(block);
            tlsf_pool.used_bytes += new_accounted - old_accounted;
            update_watermarks();
            return ptr;
        }
    }

    /* Fall back to malloc + copy + free */
    void *new_ptr = tlsf_malloc(requested);
    if (new_ptr == NULL) return NULL;
    memcpy(new_ptr, ptr, old_requested < requested ? old_requested : requested);
    tlsf_free(ptr);
    return new_ptr;
}

void *tlsf_calloc(size_t count, size_t size) {
    if (size != 0 && count > ((size_t)-1) / size) {
        tlsf_pool.alloc_fail_count++;
        return NULL;
    }
    size_t total = count * size;
    void *ptr = tlsf_malloc(total);
    if (ptr) memset(ptr, 0, total);
    return ptr;
}

/* Stats */
size_t tlsf_get_used(void) { return tlsf_pool.used_bytes; }
size_t tlsf_get_total(void) { return tlsf_pool.total_bytes; }
size_t tlsf_get_alloc_count(void) { return tlsf_pool.alloc_count; }
size_t tlsf_get_free_count(void) { return tlsf_pool.free_count; }
size_t tlsf_get_high_water(void) { return tlsf_pool.high_water_bytes; }
size_t tlsf_get_min_free(void) { return tlsf_pool.min_free_bytes; }
size_t tlsf_get_alloc_fail_count(void) { return tlsf_pool.alloc_fail_count; }
size_t tlsf_get_invalid_free_count(void) { return tlsf_pool.invalid_free_count; }
size_t tlsf_get_canary_fail_count(void) { return tlsf_pool.canary_fail_count; }
size_t tlsf_get_last_invalid_free_ptr(void) { return tlsf_pool.last_invalid_free_ptr; }
size_t tlsf_get_last_invalid_free_caller(void) { return tlsf_pool.last_invalid_free_caller; }
size_t tlsf_get_last_canary_fail_size(void) { return tlsf_pool.last_canary_fail_size; }
size_t tlsf_get_last_canary_fail_caller(void) { return tlsf_pool.last_canary_fail_caller; }
size_t tlsf_get_last_canary_fail_alloc_site(void) { return tlsf_pool.last_canary_fail_alloc_site; }
size_t tlsf_get_last_canary_fail_data(int i) { return (i >= 0 && i < 3) ? tlsf_pool.last_canary_fail_data[i] : 0; }
size_t tlsf_get_last_canary_fail_overwrite(void) { return tlsf_pool.last_canary_fail_overwrite; }
size_t tlsf_get_last_canary_fail_ptr(void) { return tlsf_pool.last_canary_fail_ptr; }
size_t tlsf_get_last_double_free_alloc_site(void) { return tlsf_pool.last_double_free_alloc_site; }
size_t tlsf_get_double_free_count(void) { return tlsf_pool.double_free_count; }
size_t tlsf_get_last_double_free_msg(void) { return last_double_free_msg; }

size_t tlsf_get_largest_free(void) {
    size_t largest = 0;
    uint8_t *p = (uint8_t *)tlsf_pool.pool_start;
    while (p + BLOCK_OVERHEAD <= (uint8_t *)tlsf_pool.pool_end) {
        block_header_t *b = (block_header_t *)p;
        if (!block_header_valid(b)) {
            break;
        }
        if (block_is_free(b) && block_size(b) > largest) {
            largest = block_size(b);
        }
        p += BLOCK_OVERHEAD + block_size(b);
    }
    return largest;
}

/* Leak census: walk USED blocks, return the requested_size accounting for the
   most total bytes, and its block count. The dominant bucket names the leaked
   object type when the heap balloons. */
static size_t census_top_size, census_top_count;
static uintptr_t census_top_alloc_site;
void tlsf_used_census(void) {
    census_top_size = 0; census_top_count = 0;
    if (tlsf_pool.pool_start == NULL) return;
    /* two-pass over a small fixed table of the 16 largest buckets */
    size_t sizes[16] = {0}, counts[16] = {0};
    uint8_t *p = (uint8_t *)tlsf_pool.pool_start;
    while (p + BLOCK_OVERHEAD <= (uint8_t *)tlsf_pool.pool_end) {
        block_header_t *b = (block_header_t *)p;
        if (!block_header_valid(b)) break;
        if (b->magic == BLOCK_MAGIC_USED) {
            size_t rs = b->requested_size;
            int slot = -1;
            for (int i = 0; i < 16; i++) {
                if (sizes[i] == rs) { slot = i; break; }
                if (sizes[i] == 0 && slot < 0) slot = i;
            }
            if (slot >= 0) { sizes[slot] = rs; counts[slot]++; }
        }
        p += BLOCK_OVERHEAD + block_size(b);
    }
    size_t best = 0;
    for (int i = 0; i < 16; i++) {
        if (sizes[i] * counts[i] > best) {
            best = sizes[i] * counts[i];
            census_top_size = sizes[i];
            census_top_count = counts[i];
        }
    }
    /* Second pass: record the alloc_site of the FIRST live block whose size
       matches the dominant bucket — names the leaking allocation site. */
    census_top_alloc_site = 0;
    p = (uint8_t *)tlsf_pool.pool_start;
    while (p + BLOCK_OVERHEAD <= (uint8_t *)tlsf_pool.pool_end) {
        block_header_t *b = (block_header_t *)p;
        if (!block_header_valid(b)) break;
        if (b->magic == BLOCK_MAGIC_USED && b->requested_size == census_top_size) {
            census_top_alloc_site = b->alloc_site;
            break;
        }
        p += BLOCK_OVERHEAD + block_size(b);
    }
}
size_t tlsf_get_census_top_size(void) { return census_top_size; }
size_t tlsf_get_census_top_count(void) { return census_top_count; }
size_t tlsf_get_census_top_alloc_site(void) { return census_top_alloc_site; }

int tlsf_check_heap(void) {
    if (tlsf_pool.pool_start == NULL || tlsf_pool.pool_end == NULL) {
        return 0;
    }
    uint8_t *p = (uint8_t *)tlsf_pool.pool_start;
    size_t accounted_used = 0;
    while (p < (uint8_t *)tlsf_pool.pool_end) {
        if (p + BLOCK_OVERHEAD > (uint8_t *)tlsf_pool.pool_end) {
            return 0;
        }
        block_header_t *b = (block_header_t *)p;
        if (!block_header_valid(b)) {
            return 0;
        }
        if (b->magic == BLOCK_MAGIC_USED) {
            if (block_is_free(b) || !tail_canary_ok(b)) {
                return 0;
            }
            accounted_used += accounted_block_size(b);
        } else if (b->magic == BLOCK_MAGIC_FREE) {
            if (!block_is_free(b)) {
                return 0;
            }
        }
        p += BLOCK_OVERHEAD + block_size(b);
    }
    if (p != (uint8_t *)tlsf_pool.pool_end) {
        return 0;
    }
    return accounted_used == tlsf_pool.used_bytes;
}

/* ========================================================================= */
/* C standard library hooks (for -d:useMalloc)                                */
/* ========================================================================= */

/* Real caller of free()/realloc() for forensics: __builtin_return_address(0)
   inside tlsf_free only ever names these wrappers, so the wrappers record
   their own caller before delegating. */
uintptr_t tlsf_last_free_site;
uintptr_t tlsf_last_alloc_site;

void *malloc(size_t size) {
    tlsf_last_alloc_site = (uintptr_t)__builtin_return_address(0);
    return tlsf_malloc(size);
}

void free(void *ptr) {
    tlsf_last_free_site = (uintptr_t)__builtin_return_address(0);
    tlsf_free(ptr);
}

void *realloc(void *ptr, size_t size) {
    tlsf_last_alloc_site = (uintptr_t)__builtin_return_address(0);
    tlsf_last_free_site = (uintptr_t)__builtin_return_address(0);
    return tlsf_realloc(ptr, size);
}

void *calloc(size_t count, size_t size) {
    tlsf_last_alloc_site = (uintptr_t)__builtin_return_address(0);
    return tlsf_calloc(count, size);
}

/* Stub _sbrk for newlib — we manage our own heap */
void *_sbrk(int incr) {
    (void)incr;
    return (void *)-1;
}
