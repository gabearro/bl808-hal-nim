/* Normal RV32 MMIE append, CMAC, frame lease and key binding. */
#include <stdint.h>
#include <stddef.h>
#include "bindings.h"

extern uint8_t vif_info_tab[3024];
extern uint64_t key_clock __asm__(KEY_CLOCK), key_changes[19] __asm__(KEY_CHANGES);
extern uint8_t error_flag __asm__(ERROR_FLAG);
extern uint8_t tx_desc_storage[880] __asm__(TX_DESC_STORAGE);
struct tx_identity {
    uint32_t generation, reset_epoch;
    uint8_t leased, reserved0[3];
    uint32_t vif_epochs[2], station_epochs[5];
    void *sm_connection;
    uint32_t sm_serial;
    uint16_t sm_state;
    uint8_t sm_tracked, reserved1;
};
struct tx_binding {
    void *descriptor, *key;
    uint64_t revision, clock;
    int32_t key_index;
    uint8_t vif, station, cipher, key_id, bip, reserved[7];
};
_Static_assert(sizeof(struct tx_identity) == 52, "TX identity ABI changed");
_Static_assert(sizeof(struct tx_binding) == 40, "TX reservation ABI changed");
_Static_assert(offsetof(struct tx_identity, leased) == 8 &&
               offsetof(struct tx_identity, vif_epochs) == 12 &&
               offsetof(struct tx_identity, station_epochs) == 20,
               "TX identity fields moved");
_Static_assert(offsetof(struct tx_binding, key_index) == 24 &&
               offsetof(struct tx_binding, vif) == 28 &&
               offsetof(struct tx_binding, bip) == 32,
               "TX reservation fields moved");
extern struct tx_identity identities[4] __asm__(FRAME_IDENTITIES);
extern uint32_t reset_epoch __asm__(RESET_EPOCH), vif_epochs[2] __asm__(VIF_EPOCHS);
extern uint32_t station_epochs[5] __asm__(STATION_EPOCHS);
extern struct tx_binding bindings[9] __asm__(SECURITY_RESERVATIONS);
extern uint32_t security_updating __asm__(SECURITY_UPDATING);
extern uint32_t mfp_add_mgmt_mic(void *, void *, uint32_t);
extern void *firmware_memcpy(void *, const void *, size_t);
extern void *memset(void *, int, size_t);
extern int memcmp(const void *, const void *, size_t);

struct profile { uint16_t length; uint8_t vif, key_id; uint64_t pn;
                 const uint8_t *frame, *expected_mmie; };
#include "vectors.h"

static uint8_t storage[8 + 512 + 8], original[8 + 512 + 8];
static uint8_t *desc, *selected;
static uint32_t cases, checks, failure, profile_index, vif, key_id, incoming, unexpected;
static uint32_t in_policy, hook_mode, hook_calls;
static const uint8_t empty_bindings[sizeof(bindings)];
static uint32_t irq(void);

void *memcpy(void *dst, const void *src, size_t count) {
    void *result = firmware_memcpy(dst, src, count);
    if (in_policy && count == 16) {
        ++hook_calls;
        if (irq() != incoming) unexpected = 5;
        if (hook_calls == 1) {
            uint32_t key_index = 7 + vif * 6 + key_id;
            struct tx_identity *identity = &identities[profile_index & 3];
            switch (hook_mode) {
            case 1:
                key_clock = 2; key_changes[key_index] = 2; selected[136] ^= 1; break;
            case 2: ++identity->generation; break;
            case 3: ++reset_epoch; break;
            case 4: ++vif_epochs[vif]; break;
            case 5: ++station_epochs[0]; break;
            case 6: {
                uint8_t *group = vif_info_tab + vif * 1512 + 1492;
                for (uint32_t i = 0; i < 4; ++i) group[i] = 0;
                break;
            }
            case 7: ++vif_epochs[vif ^ 1]; break;
            case 8: key_clock = 2; key_changes[7 + (vif ^ 1) * 6 + key_id] = 2; break;
            case 9: key_clock = 0; break;
            default: break;
            }
        }
    }
    return result;
}

static void put64(void *p, uint64_t v) {
    uint8_t *b = p; for (uint32_t i = 0; i < 8; ++i) b[i] = v >> (8 * i);
}
static uint64_t get64(const void *p) {
    const uint8_t *b = p; uint64_t v = 0;
    for (uint32_t i = 0; i < 8; ++i) v |= (uint64_t)b[i] << (8 * i);
    return v;
}
static void put32(void *p, uint32_t at, uintptr_t v) {
    uint8_t *b = p; for (uint32_t i = 0; i < 4; ++i) b[at + i] = v >> (8 * i);
}
static uint32_t irq(void) {
    uint32_t v; __asm__ volatile("csrr %0,mstatus" : "=r"(v)); return v & 8;
}
static void set_irq(uint32_t enabled) {
    if (enabled) __asm__ volatile("csrsi mstatus,8" ::: "memory");
    else __asm__ volatile("csrci mstatus,8" ::: "memory");
}
static uint32_t append(const struct profile *p) {
    in_policy = 1;
    uint32_t result = mfp_add_mgmt_mic(desc, storage + 8, p->length);
    in_policy = 0;
    return result;
}
static void prepare(const struct profile *p) {
    in_policy = hook_mode = hook_calls = 0;
    memset(tx_desc_storage, 0, sizeof(tx_desc_storage));
    memset(identities, 0, sizeof(identities));
    memset(bindings, 0, sizeof(bindings));
    memset(storage, 0xa5, sizeof(storage));
    memset(vif_info_tab, 0, sizeof(vif_info_tab)); memset(key_changes, 0, 19 * 8);
    memset(vif_epochs, 0, sizeof(vif_epochs)); memset(station_epochs, 0, sizeof(station_epochs));
    desc = tx_desc_storage + (profile_index & 3) * 220;
    reset_epoch = 7; vif_epochs[0] = 11; vif_epochs[1] = 12; station_epochs[0] = 21;
    struct tx_identity *identity = &identities[profile_index & 3];
    identity->generation = 17; identity->reset_epoch = reset_epoch;
    identity->leased = 1; identity->vif_epochs[0] = 11; identity->vif_epochs[1] = 12;
    identity->station_epochs[0] = 21;
    security_updating = 0;
    selected = vif_info_tab + p->vif * 1512 + 528 + p->key_id * 160;
    selected[152] = 5; selected[153] = p->key_id; selected[155] = 1;
    for (uint32_t i = 0; i < 16; ++i) selected[136 + i] = i;
    put64(selected + 128, p->pn);
    put32(vif_info_tab + p->vif * 1512, 1492, (uintptr_t)selected);
    desc[47] = p->vif; desc[49] = 0;
    memcpy(storage + 8, p->frame, p->length);
    memcpy(original, storage, sizeof(storage));
    unexpected = error_flag = 0;
    key_clock = 1;
    set_irq(incoming);
}
#define CHECK(condition, n) do { ++checks; if (!(condition)) { failure = (n); return (n); } } while (0)
static int valid_case(const struct profile *p) {
    prepare(p); ++cases;
    uint8_t expected[18];
    memcpy(expected, p->expected_mmie, sizeof(expected));
    if (FIXTURE_FAULT) expected[17] ^= 1;
    uint32_t ret = append(p);
    CHECK(ret == 18, 1);
    CHECK(!memcmp(storage, original, 8 + p->length), 2);
    CHECK(!memcmp(storage + 8 + p->length, expected, 18), 3);
    CHECK(get64(selected + 128) == p->pn + 1, 4);
    CHECK(irq() == incoming, 5);
    CHECK(bindings[0].descriptor == desc && bindings[0].key == selected &&
          bindings[0].key_index == 7 + p->vif * 6 + p->key_id &&
          bindings[0].vif == p->vif && bindings[0].station == 0 &&
          bindings[0].cipher == 5 && bindings[0].key_id == p->key_id &&
          bindings[0].bip == 1, 6);
    CHECK(hook_calls == 1 && !unexpected && !error_flag, 7);
    CHECK(!memcmp(storage + 8 + p->length + 18, original + 8 + p->length + 18,
                  sizeof(storage) - 8 - p->length - 18), 8);
    return 0;
}
static int exhausted_case(const struct profile *p) {
    prepare(p); ++cases; put64(selected + 128, UINT64_C(0xffffffffffff));
    uint32_t ret = append(p);
    CHECK(ret == 0, 9);
    CHECK(!memcmp(storage, original, sizeof(storage)), 10);
    CHECK(get64(selected + 128) == UINT64_C(0xffffffffffff), 11);
    CHECK(irq() == incoming, 12);
    CHECK(!memcmp(bindings, empty_bindings, sizeof(bindings)) && hook_calls == 0 &&
          !unexpected && !error_flag, 13);
    return 0;
}
static int invalid_key_case(const struct profile *p, uint32_t variant) {
    prepare(p); ++cases;
    switch (variant) {
    case 0: selected[155] = 0; break;
    case 1: selected[152] = 2; break;
    case 2: selected[153] = 3; break;
    case 3: selected[153] = p->key_id == 4 ? 5 : 4; break;
    case 4: put32(vif_info_tab + p->vif * 1512, 1492, 0); break;
    default: desc[47] = 2; break;
    }
    uint64_t pn = get64(selected + 128);
    uint32_t ret = append(p);
    CHECK(ret == 0, 14);
    CHECK(!memcmp(storage, original, sizeof(storage)), 15);
    CHECK(get64(selected + 128) == pn, 16);
    CHECK(irq() == incoming, 17);
    CHECK(!memcmp(bindings, empty_bindings, sizeof(bindings)) && hook_calls == 0 &&
          !unexpected && !error_flag, 18);
    return 0;
}
static int invalid_owner_case(const struct profile *p, uint32_t variant) {
    prepare(p); ++cases;
    struct tx_identity *identity = &identities[profile_index & 3];
    switch (variant) {
    case 0: identity->leased = 0; break;
    case 1: ++reset_epoch; break;
    case 2: ++vif_epochs[p->vif]; break;
    case 3: ++station_epochs[0]; break;
    default: security_updating = 1u << (7 + p->vif * 6 + p->key_id); break;
    }
    uint64_t pn = get64(selected + 128);
    uint32_t ret = append(p);
    CHECK(ret == 0, 19);
    CHECK(!memcmp(storage, original, sizeof(storage)), 20);
    CHECK(get64(selected + 128) == pn, 21);
    CHECK(irq() == incoming, 22);
    CHECK(!memcmp(bindings, empty_bindings, sizeof(bindings)) && hook_calls == 0 &&
          !unexpected && !error_flag, 23);
    return 0;
}
static int changed_during_mic_case(const struct profile *p, uint32_t variant) {
    prepare(p); ++cases; hook_mode = variant;
    uint32_t ret = append(p);
    uint32_t accepted = variant == 7 || variant == 8;
    CHECK(hook_calls == 1, 24);
    CHECK(ret == (accepted ? 18u : 0u), 25);
    CHECK(get64(selected + 128) == p->pn + 1, 26);
    CHECK(irq() == incoming && !unexpected && !error_flag, 27);
    if (accepted) {
        CHECK(!memcmp(storage + 8 + p->length, p->expected_mmie, 18), 28);
    } else {
        uint8_t zero_mic[8] = {0};
        CHECK(!memcmp(storage + 8 + p->length, p->expected_mmie, 10) &&
              !memcmp(storage + 8 + p->length + 10, zero_mic, 8), 28);
    }
    CHECK(bindings[0].descriptor == desc && bindings[0].key == selected &&
          bindings[0].bip == 1, 29);
    CHECK(!memcmp(storage, original, 8 + p->length) &&
          !memcmp(storage + 8 + p->length + 18,
                  original + 8 + p->length + 18,
                  sizeof(storage) - 8 - p->length - 18), 30);
    return 0;
}
int wifi_bip_tx_probe_main(void) {
    for (profile_index = 0; profile_index < PROFILE_COUNT; ++profile_index) {
        const struct profile *p = &profiles[profile_index]; vif = p->vif; key_id = p->key_id;
        for (incoming = 0; incoming <= 8; incoming += 8) {
            int result = valid_case(p); if (result) return result;
            result = exhausted_case(p); if (result) return result;
            for (uint32_t variant = 0; variant < 6; ++variant) {
                result = invalid_key_case(p, variant); if (result) return result;
            }
            for (uint32_t variant = 0; variant < 5; ++variant) {
                result = invalid_owner_case(p, variant); if (result) return result;
            }
            for (uint32_t variant = 1; variant <= 9; ++variant) {
                result = changed_during_mic_case(p, variant); if (result) return result;
            }
        }
    }
    return 0;
}
static void byte(uint8_t b) {
    volatile uint8_t *u = (void *)0x10000000; while (!(u[5] & 32)) {} u[0] = b;
}
static void hex(uint32_t v) {
    for (int s = 28; s >= 0; s -= 4) {
        uint32_t d = v >> s & 15; byte(d < 10 ? '0' + d : 'a' + d - 10);
    }
    byte(' ');
}
void wifi_bip_tx_probe_report(uint32_t result) {
    const char *s = result ? "BIPTX RV32 FAIL " : "BIPTX RV32 PASS ";
    while (*s) byte(*s++);
    hex(cases); hex(checks); hex(result); hex(failure); hex(profile_index);
    hex(vif); hex(key_id); hex(incoming); hex(unexpected); hex(error_flag); byte('\n');
}
void wifi_bip_tx_trap_report(uint32_t cause, uint32_t pc, uint32_t value) {
    const char *s = "BIPTX TRAP "; while (*s) byte(*s++);
    hex(cause); hex(pc); hex(value); byte('\n');
}
