/*
 * Bouffalo Lab BL808 SEC_ENG emulation
 *
 * Copyright (c) 2026 BL808-HAL Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/bswap.h"
#include "qemu/log.h"
#include "qapi/error.h"
#include "crypto/cipher.h"
#include "crypto/hash.h"
#include "exec/cpu-common.h"
#include "hw/irq.h"
#include "hw/misc/bl808_sec_eng.h"
#ifdef CONFIG_GNUTLS_CRYPTO
#include <gnutls/crypto.h>
#include <gnutls/gnutls.h>
#endif

#define SEC_ENG_SE_SHA_0_CTRL_OFFSET        0x000
#define SEC_ENG_SE_SHA_0_MSA_OFFSET         0x004
#define SEC_ENG_SE_SHA_0_STATUS_OFFSET      0x008
#define SEC_ENG_SE_SHA_0_ENDIAN_OFFSET      0x00c
#define SEC_ENG_SE_SHA_0_HASH_L_0_OFFSET    0x010
#define SEC_ENG_SE_SHA_0_HASH_H_0_OFFSET    0x030
#define SEC_ENG_SE_SHA_0_LINK_OFFSET        0x050
#define SEC_ENG_SE_SHA_0_CTRL_PROT_OFFSET   0x0fc
#define SEC_ENG_SE_AES_0_CTRL_OFFSET        0x100
#define SEC_ENG_SE_AES_0_MSA_OFFSET         0x104
#define SEC_ENG_SE_AES_0_MDA_OFFSET         0x108
#define SEC_ENG_SE_AES_0_STATUS_OFFSET      0x10c
#define SEC_ENG_SE_AES_0_IV_0_OFFSET        0x110
#define SEC_ENG_SE_AES_0_IV_3_OFFSET        0x11c
#define SEC_ENG_SE_AES_0_KEY_0_OFFSET       0x120
#define SEC_ENG_SE_AES_0_KEY_SEL_OFFSET     0x140
#define SEC_ENG_SE_AES_1_KEY_SEL_OFFSET     0x144
#define SEC_ENG_SE_AES_0_ENDIAN_OFFSET      0x148
#define SEC_ENG_SE_AES_0_SBOOT_OFFSET       0x14c
#define SEC_ENG_SE_AES_0_LINK_OFFSET        0x150
#define SEC_ENG_SE_AES_0_CTRL_PROT_OFFSET   0x1fc
#define SEC_ENG_SE_TRNG_0_CTRL_0_OFFSET     0x200
#define SEC_ENG_SE_TRNG_0_STATUS_OFFSET     0x204
#define SEC_ENG_SE_TRNG_0_DOUT_0_OFFSET     0x208
#define SEC_ENG_SE_TRNG_0_CTRL_PROT_OFFSET  0x2fc
#define SEC_ENG_SE_PKA_0_CTRL_0_OFFSET      0x300
#define SEC_ENG_SE_PKA_0_CTRL_1_OFFSET      0x310
#define SEC_ENG_SE_PKA_0_RW_OFFSET          0x340
#define SEC_ENG_SE_PKA_0_RW_BURST_OFFSET    0x360
#define SEC_ENG_SE_PKA_0_CTRL_PROT_OFFSET   0x3fc
#define SEC_ENG_SE_CDET_0_CTRL_0_OFFSET     0x400
#define SEC_ENG_SE_CDET_0_CTRL_1_OFFSET     0x404
#define SEC_ENG_SE_CDET_0_CTRL_2_OFFSET     0x408
#define SEC_ENG_SE_CDET_0_CTRL_3_OFFSET     0x40c
#define SEC_ENG_SE_CDET_0_CTRL_PROT_OFFSET  0x4fc
#define SEC_ENG_SE_GMAC_0_CTRL_0_OFFSET     0x500
#define SEC_ENG_SE_GMAC_0_LCA_OFFSET        0x504
#define SEC_ENG_SE_GMAC_0_STATUS_OFFSET     0x508
#define SEC_ENG_SE_GMAC_0_CTRL_PROT_OFFSET  0x5fc
#define SEC_ENG_SE_CTRL_PROT_RD_OFFSET      0xf00

#define SEC_ENG_SE_SHA_0_BUSY           BIT(0)
#define SEC_ENG_SE_SHA_0_TRIG_1T        BIT(1)
#define SEC_ENG_SE_SHA_0_MODE_SHIFT     2
#define SEC_ENG_SE_SHA_0_MODE_MASK      (0x7u << SEC_ENG_SE_SHA_0_MODE_SHIFT)
#define SEC_ENG_SE_SHA_0_EN             BIT(5)
#define SEC_ENG_SE_SHA_0_HASH_SEL       BIT(6)
#define SEC_ENG_SE_SHA_0_INT            BIT(8)
#define SEC_ENG_SE_SHA_0_INT_CLR_1T     BIT(9)
#define SEC_ENG_SE_SHA_0_INT_SET_1T     BIT(10)
#define SEC_ENG_SE_SHA_0_INT_MASK       BIT(11)
#define SEC_ENG_SE_SHA_0_MODE_EXT_SHIFT 12
#define SEC_ENG_SE_SHA_0_MODE_EXT_MASK  (0x3u << SEC_ENG_SE_SHA_0_MODE_EXT_SHIFT)
#define SEC_ENG_SE_SHA_0_LINK_MODE      BIT(15)
#define SEC_ENG_SE_SHA_0_MSG_LEN_SHIFT  16
#define SEC_ENG_SE_SHA_0_MSG_LEN_MASK   (0xffffu << SEC_ENG_SE_SHA_0_MSG_LEN_SHIFT)

#define SEC_ENG_SE_AES_0_BUSY             BIT(0)
#define SEC_ENG_SE_AES_0_TRIG_1T          BIT(1)
#define SEC_ENG_SE_AES_0_EN               BIT(2)
#define SEC_ENG_SE_AES_0_MODE_SHIFT       3
#define SEC_ENG_SE_AES_0_MODE_MASK        (0x3u << SEC_ENG_SE_AES_0_MODE_SHIFT)
#define SEC_ENG_SE_AES_0_DEC_EN           BIT(5)
#define SEC_ENG_SE_AES_0_HW_KEY_EN        BIT(7)
#define SEC_ENG_SE_AES_0_INT              BIT(8)
#define SEC_ENG_SE_AES_0_INT_CLR_1T       BIT(9)
#define SEC_ENG_SE_AES_0_INT_SET_1T       BIT(10)
#define SEC_ENG_SE_AES_0_INT_MASK         BIT(11)
#define SEC_ENG_SE_AES_0_BLOCK_MODE_SHIFT 12
#define SEC_ENG_SE_AES_0_BLOCK_MODE_MASK  (0x3u << SEC_ENG_SE_AES_0_BLOCK_MODE_SHIFT)
#define SEC_ENG_SE_AES_0_IV_SEL           BIT(14)
#define SEC_ENG_SE_AES_0_LINK_MODE        BIT(15)
#define SEC_ENG_SE_AES_0_MSG_LEN_SHIFT    16
#define SEC_ENG_SE_AES_0_MSG_LEN_MASK     (0xffffu << SEC_ENG_SE_AES_0_MSG_LEN_SHIFT)
#define SEC_ENG_SE_AES_0_SBOOT_KEY_SEL    BIT(0)

#define SEC_ENG_SE_TRNG_0_BUSY        BIT(0)
#define SEC_ENG_SE_TRNG_0_TRIG_1T     BIT(1)
#define SEC_ENG_SE_TRNG_0_EN          BIT(2)
#define SEC_ENG_SE_TRNG_0_DOUT_CLR_1T BIT(3)
#define SEC_ENG_SE_TRNG_0_INT         BIT(8)
#define SEC_ENG_SE_TRNG_0_INT_CLR_1T  BIT(9)
#define SEC_ENG_SE_TRNG_0_INT_SET_1T  BIT(10)
#define SEC_ENG_SE_TRNG_0_INT_MASK    BIT(11)

#define SEC_ENG_SE_PKA_0_DONE         BIT(0)
#define SEC_ENG_SE_PKA_0_DONE_CLR_1T  BIT(1)
#define SEC_ENG_SE_PKA_0_BUSY         BIT(2)
#define SEC_ENG_SE_PKA_0_EN           BIT(3)
#define SEC_ENG_SE_PKA_0_INT          BIT(8)
#define SEC_ENG_SE_PKA_0_INT_CLR_1T   BIT(9)
#define SEC_ENG_SE_PKA_0_INT_SET      BIT(10)
#define SEC_ENG_SE_PKA_0_INT_MASK     BIT(11)

#define SEC_ENG_SE_CDET_0_EN          BIT(0)
#define SEC_ENG_SE_CDET_0_BUSY        BIT(1)
#define SEC_ENG_SE_CDET_0_INT         BIT(8)
#define SEC_ENG_SE_CDET_0_INT_CLR     BIT(9)
#define SEC_ENG_SE_CDET_0_INT_SET     BIT(10)
#define SEC_ENG_SE_CDET_0_INT_MASK    BIT(11)
#define SEC_ENG_SE_CDET_0_MODE        BIT(12)

#define SEC_ENG_SE_GMAC_0_BUSY        BIT(0)
#define SEC_ENG_SE_GMAC_0_TRIG_1T     BIT(1)
#define SEC_ENG_SE_GMAC_0_EN          BIT(2)
#define SEC_ENG_SE_GMAC_0_INT         BIT(8)
#define SEC_ENG_SE_GMAC_0_INT_CLR_1T  BIT(9)
#define SEC_ENG_SE_GMAC_0_INT_SET_1T  BIT(10)
#define SEC_ENG_SE_GMAC_0_INT_MASK    BIT(11)

#define SEC_ENG_SE_SHA_ID0_EN_RD      BIT(0)
#define SEC_ENG_SE_SHA_ID1_EN_RD      BIT(1)
#define SEC_ENG_SE_AES_ID0_EN_RD      BIT(2)
#define SEC_ENG_SE_AES_ID1_EN_RD      BIT(3)
#define SEC_ENG_SE_TRNG_ID0_EN_RD     BIT(4)
#define SEC_ENG_SE_TRNG_ID1_EN_RD     BIT(5)
#define SEC_ENG_SE_PKA_ID0_EN_RD      BIT(6)
#define SEC_ENG_SE_PKA_ID1_EN_RD      BIT(7)
#define SEC_ENG_SE_CDET_ID0_EN_RD     BIT(8)
#define SEC_ENG_SE_CDET_ID1_EN_RD     BIT(9)
#define SEC_ENG_SE_GMAC_ID0_EN_RD     BIT(10)
#define SEC_ENG_SE_GMAC_ID1_EN_RD     BIT(11)

enum {
    BL808_SEC_ENG_IRQ_ID1_SHARED = 0,
    BL808_SEC_ENG_IRQ_ID0_SHARED = 1,
    BL808_SEC_ENG_IRQ_ID1_CDET = 2,
    BL808_SEC_ENG_IRQ_ID0_CDET = 3,
};

static uint32_t bl808_sec_eng_pair_from_bits(uint32_t value,
                                             uint32_t id0_bit,
                                             uint32_t id1_bit)
{
    return ((value & id0_bit) ? 1u : 0u) | ((value & id1_bit) ? 2u : 0u);
}

static void bl808_sec_eng_update_ctrl_prot(BL808SecEngState *s)
{
    uint32_t prot = 0;

    prot |= bl808_sec_eng_pair_from_bits(
        s->regs[SEC_ENG_SE_SHA_0_CTRL_PROT_OFFSET / 4], BIT(1), BIT(2))
            << 0;
    prot |= bl808_sec_eng_pair_from_bits(
        s->regs[SEC_ENG_SE_AES_0_CTRL_PROT_OFFSET / 4], BIT(1), BIT(2))
            << 2;
    prot |= bl808_sec_eng_pair_from_bits(
        s->regs[SEC_ENG_SE_TRNG_0_CTRL_PROT_OFFSET / 4], BIT(1), BIT(2))
            << 4;
    prot |= bl808_sec_eng_pair_from_bits(
        s->regs[SEC_ENG_SE_PKA_0_CTRL_PROT_OFFSET / 4], BIT(1), BIT(2))
            << 6;
    prot |= bl808_sec_eng_pair_from_bits(
        s->regs[SEC_ENG_SE_CDET_0_CTRL_PROT_OFFSET / 4], BIT(1), BIT(2))
            << 8;
    prot |= bl808_sec_eng_pair_from_bits(
        s->regs[SEC_ENG_SE_GMAC_0_CTRL_PROT_OFFSET / 4], BIT(1), BIT(2))
            << 10;
    s->regs[SEC_ENG_SE_CTRL_PROT_RD_OFFSET / 4] = prot;
}

static void bl808_sec_eng_set_owner(BL808SecEngState *s, hwaddr offset,
                                    uint32_t value)
{
    uint32_t reg = value & 0x7;

    switch (offset) {
    case SEC_ENG_SE_SHA_0_CTRL_PROT_OFFSET:
    case SEC_ENG_SE_AES_0_CTRL_PROT_OFFSET:
    case SEC_ENG_SE_TRNG_0_CTRL_PROT_OFFSET:
    case SEC_ENG_SE_PKA_0_CTRL_PROT_OFFSET:
    case SEC_ENG_SE_GMAC_0_CTRL_PROT_OFFSET:
        reg &= 0x6;
        break;
    case SEC_ENG_SE_CDET_0_CTRL_PROT_OFFSET:
        break;
    default:
        return;
    }

    s->regs[offset / 4] = reg;
    bl808_sec_eng_update_ctrl_prot(s);
}

static uint32_t bl808_sec_eng_owner_pair(BL808SecEngState *s, unsigned shift)
{
    return (s->regs[SEC_ENG_SE_CTRL_PROT_RD_OFFSET / 4] >> shift) & 0x3;
}

static void bl808_sec_eng_update_irq(BL808SecEngState *s)
{
    bool shared_id0 = false;
    bool shared_id1 = false;
    bool cdet_id0 = false;
    bool cdet_id1 = false;
    uint32_t pair;

    if ((s->regs[SEC_ENG_SE_AES_0_CTRL_OFFSET / 4] &
         (SEC_ENG_SE_AES_0_INT | SEC_ENG_SE_AES_0_INT_MASK)) ==
        SEC_ENG_SE_AES_0_INT) {
        pair = bl808_sec_eng_owner_pair(s, 2);
        shared_id0 |= (pair & 1) != 0;
        shared_id1 |= (pair & 2) != 0;
    }
    if ((s->regs[SEC_ENG_SE_SHA_0_CTRL_OFFSET / 4] &
         (SEC_ENG_SE_SHA_0_INT | SEC_ENG_SE_SHA_0_INT_MASK)) ==
        SEC_ENG_SE_SHA_0_INT) {
        pair = bl808_sec_eng_owner_pair(s, 0);
        shared_id0 |= (pair & 1) != 0;
        shared_id1 |= (pair & 2) != 0;
    }
    if ((s->regs[SEC_ENG_SE_TRNG_0_CTRL_0_OFFSET / 4] &
         (SEC_ENG_SE_TRNG_0_INT | SEC_ENG_SE_TRNG_0_INT_MASK)) ==
        SEC_ENG_SE_TRNG_0_INT) {
        pair = bl808_sec_eng_owner_pair(s, 4);
        shared_id0 |= (pair & 1) != 0;
        shared_id1 |= (pair & 2) != 0;
    }
    if ((s->regs[SEC_ENG_SE_PKA_0_CTRL_0_OFFSET / 4] &
         (SEC_ENG_SE_PKA_0_INT | SEC_ENG_SE_PKA_0_INT_MASK)) ==
        SEC_ENG_SE_PKA_0_INT) {
        pair = bl808_sec_eng_owner_pair(s, 6);
        shared_id0 |= (pair & 1) != 0;
        shared_id1 |= (pair & 2) != 0;
    }
    if ((s->regs[SEC_ENG_SE_GMAC_0_CTRL_0_OFFSET / 4] &
         (SEC_ENG_SE_GMAC_0_INT | SEC_ENG_SE_GMAC_0_INT_MASK)) ==
        SEC_ENG_SE_GMAC_0_INT) {
        pair = bl808_sec_eng_owner_pair(s, 10);
        shared_id0 |= (pair & 1) != 0;
        shared_id1 |= (pair & 2) != 0;
    }
    if ((s->regs[SEC_ENG_SE_CDET_0_CTRL_0_OFFSET / 4] &
         (SEC_ENG_SE_CDET_0_INT | SEC_ENG_SE_CDET_0_INT_MASK)) ==
        SEC_ENG_SE_CDET_0_INT) {
        pair = bl808_sec_eng_owner_pair(s, 8);
        cdet_id0 |= (pair & 1) != 0;
        cdet_id1 |= (pair & 2) != 0;
    }

    qemu_set_irq(s->irq[BL808_SEC_ENG_IRQ_ID1_SHARED], shared_id1);
    qemu_set_irq(s->irq[BL808_SEC_ENG_IRQ_ID0_SHARED], shared_id0);
    qemu_set_irq(s->irq[BL808_SEC_ENG_IRQ_ID1_CDET], cdet_id1);
    qemu_set_irq(s->irq[BL808_SEC_ENG_IRQ_ID0_CDET], cdet_id0);
}

static void bl808_sec_eng_sha_accum_reset(BL808SecEngState *s)
{
    g_free(s->sha_accum);
    s->sha_accum = NULL;
    s->sha_accum_len = 0;
    s->sha_accum_cap = 0;
}

static bool bl808_sec_eng_sha_accum_append(BL808SecEngState *s,
                                           const uint8_t *buf, size_t len)
{
    size_t new_len = s->sha_accum_len + len;

    if (new_len > s->sha_accum_cap) {
        size_t new_cap = MAX((size_t)256, s->sha_accum_cap);

        while (new_cap < new_len) {
            new_cap *= 2;
        }
        s->sha_accum = g_realloc(s->sha_accum, new_cap);
        s->sha_accum_cap = new_cap;
    }

    memcpy(s->sha_accum + s->sha_accum_len, buf, len);
    s->sha_accum_len = new_len;
    return true;
}

static uint8_t *bl808_sec_eng_read_guest(hwaddr addr, size_t len)
{
    uint8_t *buf;

    if (len == 0) {
        return g_new0(uint8_t, 1);
    }

    buf = g_new(uint8_t, len);
    cpu_physical_memory_read(addr, buf, len);
    return buf;
}

static bool bl808_sec_eng_hw_key_slot_offset(uint32_t slot, hwaddr *offset)
{
    switch (slot) {
    case 0:
        *offset = 0x1c;
        return true;
    case 1:
        *offset = 0x2c;
        return true;
    case 2:
        *offset = 0x3c;
        return true;
    case 3:
        *offset = 0x4c;
        return true;
    case 4:
        *offset = 0x80;
        return true;
    case 5:
        *offset = 0x90;
        return true;
    default:
        return false;
    }
}

static bool bl808_sec_eng_load_hw_key_slot(BL808SecEngState *s, uint32_t slot,
                                           uint8_t *key, size_t key_len)
{
    hwaddr offset;
    size_t words = DIV_ROUND_UP(key_len, 4);
    size_t word_base;

    /*
     * BL808 efuse key slots are exposed through the EF_CTRL shadow window as
     * 32-bit little-endian words; slot2 starts at offset 0x3c in the BL808
     * SDK examples.
     */
    if (!s->efuse_shadow ||
        !bl808_sec_eng_hw_key_slot_offset(slot, &offset)) {
        return false;
    }

    word_base = offset / sizeof(uint32_t);
    if (word_base + words > s->efuse_words) {
        return false;
    }

    for (size_t i = 0; i < words; i++) {
        stl_le_p(key + i * 4, s->efuse_shadow[word_base + i]);
    }
    return true;
}

static uint64_t bl808_sec_eng_rotr64(uint64_t value, unsigned shift)
{
    return (value >> shift) | (value << (64 - shift));
}

static uint64_t bl808_sec_eng_sha512_ch(uint64_t x, uint64_t y, uint64_t z)
{
    return (x & y) ^ (~x & z);
}

static uint64_t bl808_sec_eng_sha512_maj(uint64_t x, uint64_t y, uint64_t z)
{
    return (x & y) ^ (x & z) ^ (y & z);
}

static uint64_t bl808_sec_eng_sha512_sigma0(uint64_t x)
{
    return bl808_sec_eng_rotr64(x, 28) ^
           bl808_sec_eng_rotr64(x, 34) ^
           bl808_sec_eng_rotr64(x, 39);
}

static uint64_t bl808_sec_eng_sha512_sigma1(uint64_t x)
{
    return bl808_sec_eng_rotr64(x, 14) ^
           bl808_sec_eng_rotr64(x, 18) ^
           bl808_sec_eng_rotr64(x, 41);
}

static uint64_t bl808_sec_eng_sha512_gamma0(uint64_t x)
{
    return bl808_sec_eng_rotr64(x, 1) ^
           bl808_sec_eng_rotr64(x, 8) ^
           (x >> 7);
}

static uint64_t bl808_sec_eng_sha512_gamma1(uint64_t x)
{
    return bl808_sec_eng_rotr64(x, 19) ^
           bl808_sec_eng_rotr64(x, 61) ^
           (x >> 6);
}

static void bl808_sec_eng_sha512_process_block(uint64_t state[8],
                                               const uint8_t block[128])
{
    static const uint64_t k[80] = {
        UINT64_C(0x428a2f98d728ae22), UINT64_C(0x7137449123ef65cd),
        UINT64_C(0xb5c0fbcfec4d3b2f), UINT64_C(0xe9b5dba58189dbbc),
        UINT64_C(0x3956c25bf348b538), UINT64_C(0x59f111f1b605d019),
        UINT64_C(0x923f82a4af194f9b), UINT64_C(0xab1c5ed5da6d8118),
        UINT64_C(0xd807aa98a3030242), UINT64_C(0x12835b0145706fbe),
        UINT64_C(0x243185be4ee4b28c), UINT64_C(0x550c7dc3d5ffb4e2),
        UINT64_C(0x72be5d74f27b896f), UINT64_C(0x80deb1fe3b1696b1),
        UINT64_C(0x9bdc06a725c71235), UINT64_C(0xc19bf174cf692694),
        UINT64_C(0xe49b69c19ef14ad2), UINT64_C(0xefbe4786384f25e3),
        UINT64_C(0x0fc19dc68b8cd5b5), UINT64_C(0x240ca1cc77ac9c65),
        UINT64_C(0x2de92c6f592b0275), UINT64_C(0x4a7484aa6ea6e483),
        UINT64_C(0x5cb0a9dcbd41fbd4), UINT64_C(0x76f988da831153b5),
        UINT64_C(0x983e5152ee66dfab), UINT64_C(0xa831c66d2db43210),
        UINT64_C(0xb00327c898fb213f), UINT64_C(0xbf597fc7beef0ee4),
        UINT64_C(0xc6e00bf33da88fc2), UINT64_C(0xd5a79147930aa725),
        UINT64_C(0x06ca6351e003826f), UINT64_C(0x142929670a0e6e70),
        UINT64_C(0x27b70a8546d22ffc), UINT64_C(0x2e1b21385c26c926),
        UINT64_C(0x4d2c6dfc5ac42aed), UINT64_C(0x53380d139d95b3df),
        UINT64_C(0x650a73548baf63de), UINT64_C(0x766a0abb3c77b2a8),
        UINT64_C(0x81c2c92e47edaee6), UINT64_C(0x92722c851482353b),
        UINT64_C(0xa2bfe8a14cf10364), UINT64_C(0xa81a664bbc423001),
        UINT64_C(0xc24b8b70d0f89791), UINT64_C(0xc76c51a30654be30),
        UINT64_C(0xd192e819d6ef5218), UINT64_C(0xd69906245565a910),
        UINT64_C(0xf40e35855771202a), UINT64_C(0x106aa07032bbd1b8),
        UINT64_C(0x19a4c116b8d2d0c8), UINT64_C(0x1e376c085141ab53),
        UINT64_C(0x2748774cdf8eeb99), UINT64_C(0x34b0bcb5e19b48a8),
        UINT64_C(0x391c0cb3c5c95a63), UINT64_C(0x4ed8aa4ae3418acb),
        UINT64_C(0x5b9cca4f7763e373), UINT64_C(0x682e6ff3d6b2b8a3),
        UINT64_C(0x748f82ee5defb2fc), UINT64_C(0x78a5636f43172f60),
        UINT64_C(0x84c87814a1f0ab72), UINT64_C(0x8cc702081a6439ec),
        UINT64_C(0x90befffa23631e28), UINT64_C(0xa4506cebde82bde9),
        UINT64_C(0xbef9a3f7b2c67915), UINT64_C(0xc67178f2e372532b),
        UINT64_C(0xca273eceea26619c), UINT64_C(0xd186b8c721c0c207),
        UINT64_C(0xeada7dd6cde0eb1e), UINT64_C(0xf57d4f7fee6ed178),
        UINT64_C(0x06f067aa72176fba), UINT64_C(0x0a637dc5a2c898a6),
        UINT64_C(0x113f9804bef90dae), UINT64_C(0x1b710b35131c471b),
        UINT64_C(0x28db77f523047d84), UINT64_C(0x32caab7b40c72493),
        UINT64_C(0x3c9ebe0a15c9bebc), UINT64_C(0x431d67c49c100d4c),
        UINT64_C(0x4cc5d4becb3e42b6), UINT64_C(0x597f299cfc657e2a),
        UINT64_C(0x5fcb6fab3ad6faec), UINT64_C(0x6c44198c4a475817)
    };
    uint64_t w[80];
    uint64_t a, b, c, d, e, f, g, h;

    for (size_t i = 0; i < 16; i++) {
        w[i] = ldq_be_p(block + i * 8);
    }
    for (size_t i = 16; i < 80; i++) {
        w[i] = bl808_sec_eng_sha512_gamma1(w[i - 2]) + w[i - 7] +
               bl808_sec_eng_sha512_gamma0(w[i - 15]) + w[i - 16];
    }

    a = state[0];
    b = state[1];
    c = state[2];
    d = state[3];
    e = state[4];
    f = state[5];
    g = state[6];
    h = state[7];

    for (size_t i = 0; i < 80; i++) {
        uint64_t t1 = h + bl808_sec_eng_sha512_sigma1(e) +
                      bl808_sec_eng_sha512_ch(e, f, g) + k[i] + w[i];
        uint64_t t2 = bl808_sec_eng_sha512_sigma0(a) +
                      bl808_sec_eng_sha512_maj(a, b, c);

        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

static void bl808_sec_eng_sha512_custom(const uint8_t *data, size_t len,
                                        const uint64_t iv[8], uint8_t *digest,
                                        size_t digest_len)
{
    uint64_t state[8];
    uint8_t final_blocks[256] = { 0 };
    size_t rem = len % 128;
    size_t blocks = len / 128;
    size_t final_len = rem + 1 + 16;
    size_t padded_len = (final_len <= 128) ? 128 : 256;
    uint64_t bit_len_hi = (uint64_t)(len >> 61);
    uint64_t bit_len_lo = (uint64_t)(len << 3);
    uint8_t full_digest[64];

    memcpy(state, iv, sizeof(state));
    for (size_t i = 0; i < blocks; i++) {
        bl808_sec_eng_sha512_process_block(state, data + i * 128);
    }

    if (rem) {
        memcpy(final_blocks, data + blocks * 128, rem);
    }
    final_blocks[rem] = 0x80;
    stq_be_p(final_blocks + padded_len - 16, bit_len_hi);
    stq_be_p(final_blocks + padded_len - 8, bit_len_lo);

    bl808_sec_eng_sha512_process_block(state, final_blocks);
    if (padded_len == 256) {
        bl808_sec_eng_sha512_process_block(state, final_blocks + 128);
    }

    for (size_t i = 0; i < 8; i++) {
        stq_be_p(full_digest + i * 8, state[i]);
    }
    memcpy(digest, full_digest, digest_len);
}

static bool bl808_sec_eng_sha512_t_hash(BL808SecEngState *s, uint32_t mode,
                                        uint8_t **digest, size_t *digest_len)
{
    static const uint64_t sha512_224_iv[8] = {
        UINT64_C(0x8c3d37c819544da2), UINT64_C(0x73e1996689dcd4d6),
        UINT64_C(0x1dfab7ae32ff9c82), UINT64_C(0x679dd514582f9fcf),
        UINT64_C(0x0f6d2b697bd44da8), UINT64_C(0x77e36f7304c48942),
        UINT64_C(0x3f9d85a86a1d36c8), UINT64_C(0x1112e6ad91d692a1),
    };
    static const uint64_t sha512_256_iv[8] = {
        UINT64_C(0x22312194fc2bf72c), UINT64_C(0x9f555fa3c84c64c2),
        UINT64_C(0x2393b86b6f53b151), UINT64_C(0x963877195940eabd),
        UINT64_C(0x96283ee2a88effe3), UINT64_C(0xbe5e1e2553863992),
        UINT64_C(0x2b0199fc2c85b8aa), UINT64_C(0x0eb72ddc81c52ca2),
    };
    const uint64_t *iv;

    switch (mode) {
    case 6:
        iv = sha512_224_iv;
        *digest_len = 28;
        break;
    case 7:
        iv = sha512_256_iv;
        *digest_len = 32;
        break;
    default:
        return false;
    }

    *digest = g_new0(uint8_t, *digest_len);
    bl808_sec_eng_sha512_custom(s->sha_accum, s->sha_accum_len, iv,
                                *digest, *digest_len);
    return true;
}

static uint32_t bl808_sec_eng_ldl(hwaddr addr)
{
    uint32_t value;

    cpu_physical_memory_read(addr, &value, sizeof(value));
    return le32_to_cpu(value);
}

static void bl808_sec_eng_store_words_le(BL808SecEngState *s, hwaddr offset,
                                         const uint8_t *buf, size_t len,
                                         size_t max_words)
{
    uint8_t tmp[64] = { 0 };
    size_t copy_len = MIN(len, sizeof(tmp));

    memcpy(tmp, buf, copy_len);
    for (size_t i = 0; i < max_words; i++) {
        s->regs[offset / 4 + i] = ldl_le_p(tmp + i * 4);
    }
}

static uint32_t bl808_sec_eng_reflect_bits(uint32_t value, unsigned width)
{
    uint32_t reflected = 0;

    for (unsigned i = 0; i < width; i++) {
        if (value & (1u << i)) {
            reflected |= 1u << (width - 1 - i);
        }
    }
    return reflected;
}

static uint32_t bl808_sec_eng_crc_mask(unsigned width)
{
    return width == 32 ? UINT32_MAX : ((1u << width) - 1);
}

static uint32_t bl808_sec_eng_crc_update(const uint8_t *data, size_t len,
                                         unsigned width, uint32_t poly,
                                         uint32_t crc, bool din_ref)
{
    uint32_t mask = bl808_sec_eng_crc_mask(width);

    crc &= mask;
    poly &= mask;

    if (din_ref) {
        uint32_t poly_ref = bl808_sec_eng_reflect_bits(poly, width);

        for (size_t i = 0; i < len; i++) {
            crc ^= data[i];
            for (unsigned bit = 0; bit < 8; bit++) {
                if (crc & 1u) {
                    crc = (crc >> 1) ^ poly_ref;
                } else {
                    crc >>= 1;
                }
                crc &= mask;
            }
        }
    } else {
        uint32_t top = 1u << (width - 1);

        for (size_t i = 0; i < len; i++) {
            crc ^= (uint32_t)data[i] << (width - 8);
            for (unsigned bit = 0; bit < 8; bit++) {
                if (crc & top) {
                    crc = ((crc << 1) & mask) ^ poly;
                } else {
                    crc = (crc << 1) & mask;
                }
            }
        }
    }

    return crc & mask;
}

static uint32_t bl808_sec_eng_crc_finalize(unsigned width, uint32_t crc,
                                           bool din_ref, bool dout_ref,
                                           bool dout_inv)
{
    uint32_t mask = bl808_sec_eng_crc_mask(width);

    crc &= mask;
    if (dout_ref != din_ref) {
        crc = bl808_sec_eng_reflect_bits(crc, width);
    }
    if (dout_inv) {
        crc ^= mask;
    }
    return crc & mask;
}

static uint32_t bl808_sec_eng_crc_restore_state(unsigned width,
                                                uint32_t stored_crc,
                                                bool din_ref, bool dout_ref,
                                                bool dout_inv)
{
    uint32_t mask = bl808_sec_eng_crc_mask(width);

    stored_crc &= mask;
    if (dout_inv) {
        stored_crc ^= mask;
    }
    if (dout_ref != din_ref) {
        stored_crc = bl808_sec_eng_reflect_bits(stored_crc, width);
    }
    return stored_crc & mask;
}

static uint32_t bl808_sec_eng_sha_mode(uint32_t ctrl)
{
    return (ctrl & SEC_ENG_SE_SHA_0_MODE_MASK) >>
           SEC_ENG_SE_SHA_0_MODE_SHIFT;
}

static uint32_t bl808_sec_eng_sha_mode_ext(uint32_t ctrl)
{
    return (ctrl & SEC_ENG_SE_SHA_0_MODE_EXT_MASK) >>
           SEC_ENG_SE_SHA_0_MODE_EXT_SHIFT;
}

static bool bl808_sec_eng_sha_is_64bit(uint32_t ctrl)
{
    switch (bl808_sec_eng_sha_mode(ctrl)) {
    case 4:
    case 5:
    case 6:
    case 7:
        return true;
    default:
        return false;
    }
}

static void bl808_sec_eng_clear_sha_output(BL808SecEngState *s)
{
    memset(&s->regs[SEC_ENG_SE_SHA_0_HASH_L_0_OFFSET / 4], 0,
           16 * sizeof(uint32_t));
}

static void bl808_sec_eng_store_sha_output(BL808SecEngState *s, uint32_t ctrl,
                                           const uint8_t *digest,
                                           size_t digest_len)
{
    uint8_t word_buf[4] = { 0 };
    size_t words = DIV_ROUND_UP(digest_len, sizeof(word_buf));

    bl808_sec_eng_clear_sha_output(s);

    if (!bl808_sec_eng_sha_is_64bit(ctrl)) {
        bl808_sec_eng_store_words_le(s, SEC_ENG_SE_SHA_0_HASH_L_0_OFFSET,
                                     digest, digest_len, 16);
        return;
    }

    for (size_t i = 0; i < words; i++) {
        size_t copy_len = MIN(sizeof(word_buf), digest_len - i * sizeof(word_buf));
        uint32_t reg;
        hwaddr reg_off;

        memset(word_buf, 0, sizeof(word_buf));
        memcpy(word_buf, digest + i * sizeof(word_buf), copy_len);
        reg = ldl_le_p(word_buf);
        if ((i & 1) == 0) {
            reg_off = SEC_ENG_SE_SHA_0_HASH_H_0_OFFSET + (i / 2) * 4;
        } else {
            reg_off = SEC_ENG_SE_SHA_0_HASH_L_0_OFFSET + (i / 2) * 4;
        }
        s->regs[reg_off / 4] = reg;
    }
}

static void bl808_sec_eng_store_sha_link_output(hwaddr link_addr,
                                                const uint8_t *digest,
                                                size_t digest_len)
{
    uint8_t zero[64] = { 0 };

    cpu_physical_memory_write(link_addr + 8, zero, sizeof(zero));
    if (digest_len) {
        cpu_physical_memory_write(link_addr + 8, digest, digest_len);
    }
}

static bool bl808_sec_eng_sha_hash(BL808SecEngState *s, uint32_t ctrl,
                                   uint8_t **digest, size_t *digest_len)
{
    QCryptoHashAlgo alg;
    uint32_t mode = bl808_sec_eng_sha_mode(ctrl);
    uint32_t mode_ext = bl808_sec_eng_sha_mode_ext(ctrl);
    Error *local_err = NULL;

    *digest = NULL;
    *digest_len = 0;

    if (mode_ext == 1) {
        alg = QCRYPTO_HASH_ALGO_MD5;
    } else if (mode_ext == 2 || mode_ext == 3) {
        /*
         * CRC16/CRC32 are serviced by the dedicated CRC path before the
         * generic hash backend is reached.
         */
        return false;
    } else if (mode_ext != 0) {
        qemu_log_mask(LOG_UNIMP,
                      "bl808_sec_eng: SHA mode-ext %u not implemented\n",
                      mode_ext);
        return false;
    } else {
        switch (mode) {
        case 0:
            alg = QCRYPTO_HASH_ALGO_SHA256;
            break;
        case 1:
            alg = QCRYPTO_HASH_ALGO_SHA224;
            break;
        case 2:
        case 3:
            alg = QCRYPTO_HASH_ALGO_SHA1;
            break;
        case 4:
            alg = QCRYPTO_HASH_ALGO_SHA512;
            break;
        case 5:
            alg = QCRYPTO_HASH_ALGO_SHA384;
            break;
        case 6:
        case 7:
            return bl808_sec_eng_sha512_t_hash(s, mode, digest, digest_len);
        default:
            qemu_log_mask(LOG_UNIMP,
                          "bl808_sec_eng: SHA mode %u not implemented\n",
                          mode);
            return false;
        }
    }

    if (qcrypto_hash_bytes(alg, (const char *)s->sha_accum, s->sha_accum_len,
                           digest, digest_len, &local_err) < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sec_eng: SHA operation failed: %s\n",
                      error_get_pretty(local_err));
        error_free(local_err);
        return false;
    }

    return true;
}

static size_t bl808_sec_eng_sha_block_bytes(uint32_t ctrl)
{
    uint32_t mode_ext = bl808_sec_eng_sha_mode_ext(ctrl);
    uint32_t mode = bl808_sec_eng_sha_mode(ctrl);

    if (mode_ext == 1) {
        return 64;
    }
    if (mode_ext == 2 || mode_ext == 3) {
        return 4;
    }
    return (mode == 4 || mode == 5 || mode == 6 || mode == 7) ? 128 : 64;
}

static bool bl808_sec_eng_run_crc_link(BL808SecEngState *s, hwaddr link_addr,
                                       uint32_t ctrl)
{
    uint32_t mode_ext = bl808_sec_eng_sha_mode_ext(ctrl);
    unsigned width;
    uint32_t blocks = (ctrl & SEC_ENG_SE_SHA_0_MSG_LEN_MASK) >>
                      SEC_ENG_SE_SHA_0_MSG_LEN_SHIFT;
    size_t total_len = (size_t)blocks * 4u;
    hwaddr src = bl808_sec_eng_ldl(link_addr + 4);
    uint32_t poly = bl808_sec_eng_ldl(link_addr + 8);
    uint32_t crc_ctrl = bl808_sec_eng_ldl(link_addr + 12);
    uint32_t iv_and_hash = bl808_sec_eng_ldl(link_addr + 16);
    bool dout_inv = (crc_ctrl & BIT(0)) != 0;
    bool dout_ref = (crc_ctrl & BIT(1)) != 0;
    bool din_ref = (crc_ctrl & BIT(2)) != 0;
    uint32_t crc;
    g_autofree uint8_t *data = NULL;
    uint8_t out_le[4] = { 0 };

    switch (mode_ext) {
    case 2:
        width = 16;
        break;
    case 3:
        width = 32;
        break;
    default:
        return false;
    }

    if (ctrl & SEC_ENG_SE_SHA_0_HASH_SEL) {
        crc = bl808_sec_eng_crc_restore_state(width, iv_and_hash,
                                              din_ref, dout_ref, dout_inv);
    } else {
        crc = iv_and_hash & bl808_sec_eng_crc_mask(width);
    }

    data = bl808_sec_eng_read_guest(src, total_len);
    crc = bl808_sec_eng_crc_update(data, total_len, width, poly, crc, din_ref);
    crc = bl808_sec_eng_crc_finalize(width, crc, din_ref, dout_ref, dout_inv);

    bl808_sec_eng_clear_sha_output(s);
    s->regs[SEC_ENG_SE_SHA_0_HASH_L_0_OFFSET / 4] = crc;
    stl_le_p(out_le, crc);
    cpu_physical_memory_write(link_addr + 16, out_le, sizeof(out_le));
    return true;
}

static bool bl808_sec_eng_run_crc_direct(BL808SecEngState *s, uint32_t ctrl)
{
    uint32_t mode_ext = bl808_sec_eng_sha_mode_ext(ctrl);
    unsigned width;
    uint32_t poly;
    bool dout_inv;
    bool dout_ref;
    bool din_ref;
    uint32_t crc;
    uint32_t blocks = (ctrl & SEC_ENG_SE_SHA_0_MSG_LEN_MASK) >>
                      SEC_ENG_SE_SHA_0_MSG_LEN_SHIFT;
    size_t total_len = (size_t)blocks * 4u;
    hwaddr src = s->regs[SEC_ENG_SE_SHA_0_MSA_OFFSET / 4];
    g_autofree uint8_t *data = NULL;

    switch (mode_ext) {
    case 2:
        /*
         * The SDK's software CRC16 fallback uses the reflected 0x8005
         * polynomial with init 0xffff and no final xor.
         */
        width = 16;
        poly = 0x8005;
        dout_inv = false;
        dout_ref = true;
        din_ref = true;
        crc = 0xffff;
        break;
    case 3:
        /*
         * The SDK's software CRC32 fallback uses the standard reflected
         * 0x04c11db7 polynomial with init/xorout 0xffffffff.
         */
        width = 32;
        poly = 0x04c11db7;
        dout_inv = true;
        dout_ref = true;
        din_ref = true;
        crc = 0xffffffff;
        break;
    default:
        return false;
    }

    if (ctrl & SEC_ENG_SE_SHA_0_HASH_SEL) {
        crc = bl808_sec_eng_crc_restore_state(
            width, s->regs[SEC_ENG_SE_SHA_0_HASH_L_0_OFFSET / 4],
            din_ref, dout_ref, dout_inv);
    }

    data = bl808_sec_eng_read_guest(src, total_len);
    crc = bl808_sec_eng_crc_update(data, total_len, width, poly, crc, din_ref);
    crc = bl808_sec_eng_crc_finalize(width, crc, din_ref, dout_ref, dout_inv);

    bl808_sec_eng_clear_sha_output(s);
    s->regs[SEC_ENG_SE_SHA_0_HASH_L_0_OFFSET / 4] = crc;
    return true;
}

static void bl808_sec_eng_complete_sha(BL808SecEngState *s, uint32_t ctrl)
{
    s->regs[SEC_ENG_SE_SHA_0_CTRL_OFFSET / 4] =
        ctrl & ~SEC_ENG_SE_SHA_0_BUSY & ~SEC_ENG_SE_SHA_0_TRIG_1T;
    s->regs[SEC_ENG_SE_SHA_0_CTRL_OFFSET / 4] |= SEC_ENG_SE_SHA_0_INT;
}

static void bl808_sec_eng_run_sha(BL808SecEngState *s, uint32_t ctrl)
{
    bool link_mode = (ctrl & SEC_ENG_SE_SHA_0_LINK_MODE) != 0;
    uint32_t work_ctrl = ctrl;
    uint32_t mode_ext;
    hwaddr src;
    hwaddr link_addr = 0;
    uint32_t blocks;
    size_t total_len;
    uint8_t *data;
    uint8_t *digest = NULL;
    size_t digest_len = 0;

    if (link_mode) {
        link_addr = s->regs[SEC_ENG_SE_SHA_0_LINK_OFFSET / 4];
        work_ctrl = bl808_sec_eng_ldl(link_addr);
        mode_ext = bl808_sec_eng_sha_mode_ext(work_ctrl);
        if (mode_ext == 2 || mode_ext == 3) {
            if (!bl808_sec_eng_run_crc_link(s, link_addr, work_ctrl)) {
                bl808_sec_eng_clear_sha_output(s);
            }
            s->regs[SEC_ENG_SE_SHA_0_STATUS_OFFSET / 4] = 0;
            bl808_sec_eng_complete_sha(s, ctrl);
            bl808_sec_eng_update_irq(s);
            return;
        }
        src = bl808_sec_eng_ldl(link_addr + 4);
        blocks = (work_ctrl & SEC_ENG_SE_SHA_0_MSG_LEN_MASK) >>
                 SEC_ENG_SE_SHA_0_MSG_LEN_SHIFT;
        total_len = (size_t)blocks * bl808_sec_eng_sha_block_bytes(work_ctrl);
        if (!(work_ctrl & SEC_ENG_SE_SHA_0_HASH_SEL)) {
            bl808_sec_eng_sha_accum_reset(s);
        }
        data = bl808_sec_eng_read_guest(src, total_len);
        bl808_sec_eng_sha_accum_append(s, data, total_len);
        g_free(data);
        if (bl808_sec_eng_sha_hash(s, work_ctrl, &digest, &digest_len)) {
            bl808_sec_eng_store_sha_output(s, work_ctrl, digest, digest_len);
            bl808_sec_eng_store_sha_link_output(link_addr, digest, digest_len);
            g_free(digest);
        } else {
            bl808_sec_eng_clear_sha_output(s);
            bl808_sec_eng_store_sha_link_output(link_addr, NULL, 0);
        }
    } else {
        mode_ext = bl808_sec_eng_sha_mode_ext(ctrl);
        if (mode_ext == 2 || mode_ext == 3) {
            if (!bl808_sec_eng_run_crc_direct(s, ctrl)) {
                bl808_sec_eng_clear_sha_output(s);
            }
            s->regs[SEC_ENG_SE_SHA_0_STATUS_OFFSET / 4] = 0;
            bl808_sec_eng_complete_sha(s, ctrl);
            bl808_sec_eng_update_irq(s);
            return;
        }
        src = s->regs[SEC_ENG_SE_SHA_0_MSA_OFFSET / 4];
        blocks = (ctrl & SEC_ENG_SE_SHA_0_MSG_LEN_MASK) >>
                 SEC_ENG_SE_SHA_0_MSG_LEN_SHIFT;
        total_len = (size_t)blocks * bl808_sec_eng_sha_block_bytes(ctrl);
        if (!(ctrl & SEC_ENG_SE_SHA_0_HASH_SEL)) {
            bl808_sec_eng_sha_accum_reset(s);
        }
        data = bl808_sec_eng_read_guest(src, total_len);
        bl808_sec_eng_sha_accum_append(s, data, total_len);
        g_free(data);
        if (bl808_sec_eng_sha_hash(s, ctrl, &digest, &digest_len)) {
            bl808_sec_eng_store_sha_output(s, ctrl, digest, digest_len);
            g_free(digest);
        } else {
            bl808_sec_eng_clear_sha_output(s);
        }
    }

    s->regs[SEC_ENG_SE_SHA_0_STATUS_OFFSET / 4] = 0;
    bl808_sec_eng_complete_sha(s, ctrl);
    bl808_sec_eng_update_irq(s);
}

static bool bl808_sec_eng_aes_mode(uint32_t ctrl, QCryptoCipherMode *mode)
{
    switch ((ctrl & SEC_ENG_SE_AES_0_BLOCK_MODE_MASK) >>
            SEC_ENG_SE_AES_0_BLOCK_MODE_SHIFT) {
    case 0:
        *mode = QCRYPTO_CIPHER_MODE_ECB;
        return true;
    case 1:
        *mode = QCRYPTO_CIPHER_MODE_CTR;
        return true;
    case 2:
        *mode = QCRYPTO_CIPHER_MODE_CBC;
        return true;
    case 3:
        *mode = QCRYPTO_CIPHER_MODE_XTS;
        return true;
    default:
        return false;
    }
}

static bool bl808_sec_eng_build_aes_key_regs(BL808SecEngState *s, uint32_t ctrl,
                                             uint8_t *key, size_t *key_len,
                                             QCryptoCipherAlgo *alg)
{
    QCryptoCipherMode mode;
    uint32_t key_mode = (ctrl & SEC_ENG_SE_AES_0_MODE_MASK) >>
                        SEC_ENG_SE_AES_0_MODE_SHIFT;
    size_t reg_key_len;

    if (!bl808_sec_eng_aes_mode(ctrl, &mode)) {
        return false;
    }

    if (mode == QCRYPTO_CIPHER_MODE_XTS) {
        switch (key_mode) {
        case 0:
            *alg = QCRYPTO_CIPHER_ALGO_AES_128;
            *key_len = 32;
            reg_key_len = 32;
            break;
        case 1:
            /*
             * The BL808 SDK programs direct XTS-256 with a single 256-bit key
             * in KEY0..KEY7 and reuses it for both XTS halves.
             */
            *alg = QCRYPTO_CIPHER_ALGO_AES_256;
            *key_len = 64;
            reg_key_len = 32;
            break;
        case 2:
            /*
             * The direct XTS-192 path similarly exposes one 192-bit key in
             * KEY0..KEY5 and uses the same material for both halves.
             */
            *alg = QCRYPTO_CIPHER_ALGO_AES_192;
            *key_len = 48;
            reg_key_len = 24;
            break;
        case 3:
            *alg = QCRYPTO_CIPHER_ALGO_AES_128;
            *key_len = 32;
            reg_key_len = 32;
            break;
        default:
            qemu_log_mask(LOG_UNIMP,
                          "bl808_sec_eng: AES direct XTS key mode %u unsupported\n",
                          key_mode);
            return false;
        }
    } else {
        switch (key_mode) {
        case 0:
            *alg = QCRYPTO_CIPHER_ALGO_AES_128;
            *key_len = 16;
            reg_key_len = 16;
            break;
        case 1:
            *alg = QCRYPTO_CIPHER_ALGO_AES_256;
            *key_len = 32;
            reg_key_len = 32;
            break;
        case 2:
            *alg = QCRYPTO_CIPHER_ALGO_AES_192;
            *key_len = 24;
            reg_key_len = 24;
            break;
        default:
            qemu_log_mask(LOG_UNIMP,
                          "bl808_sec_eng: AES key mode %u unsupported\n",
                          key_mode);
            return false;
        }
    }

    for (size_t i = 0; i < DIV_ROUND_UP(reg_key_len, 4); i++) {
        stl_le_p(key + i * 4, s->regs[SEC_ENG_SE_AES_0_KEY_0_OFFSET / 4 + i]);
    }

    if (mode == QCRYPTO_CIPHER_MODE_XTS &&
        (key_mode == 1 || key_mode == 2)) {
        memcpy(key + reg_key_len, key, reg_key_len);
    }

    return true;
}

static bool bl808_sec_eng_build_aes_hw_key(BL808SecEngState *s, uint32_t ctrl,
                                           uint8_t *key, size_t *key_len,
                                           QCryptoCipherAlgo *alg)
{
    QCryptoCipherMode mode;
    uint32_t key_mode = (ctrl & SEC_ENG_SE_AES_0_MODE_MASK) >>
                        SEC_ENG_SE_AES_0_MODE_SHIFT;
    uint32_t keysel0 = s->regs[SEC_ENG_SE_AES_0_KEY_SEL_OFFSET / 4] & 0x3;
    uint32_t keysel1 = s->regs[SEC_ENG_SE_AES_1_KEY_SEL_OFFSET / 4] & 0x3;
    bool sboot_source =
        (s->regs[SEC_ENG_SE_AES_0_SBOOT_OFFSET / 4] &
         SEC_ENG_SE_AES_0_SBOOT_KEY_SEL) != 0;

    if (sboot_source) {
        qemu_log_mask(LOG_UNIMP,
                      "bl808_sec_eng: AES hardware key source 1 unsupported\n");
        return false;
    }
    if (!bl808_sec_eng_aes_mode(ctrl, &mode)) {
        return false;
    }

    if (mode == QCRYPTO_CIPHER_MODE_XTS) {
        switch (key_mode) {
        case 0:
        case 3:
            *alg = QCRYPTO_CIPHER_ALGO_AES_128;
            *key_len = 32;
            return bl808_sec_eng_load_hw_key_slot(s, keysel0, key, 16) &&
                   bl808_sec_eng_load_hw_key_slot(s, keysel1, key + 16, 16);
        default:
            qemu_log_mask(LOG_UNIMP,
                          "bl808_sec_eng: AES hardware XTS key mode %u unsupported\n",
                          key_mode);
            return false;
        }
    }

    switch (key_mode) {
    case 0:
        *alg = QCRYPTO_CIPHER_ALGO_AES_128;
        *key_len = 16;
        return bl808_sec_eng_load_hw_key_slot(s, keysel0, key, *key_len);
    case 1:
        *alg = QCRYPTO_CIPHER_ALGO_AES_256;
        *key_len = 32;
        return bl808_sec_eng_load_hw_key_slot(s, keysel0, key, 16) &&
               bl808_sec_eng_load_hw_key_slot(s, keysel1, key + 16, 16);
    default:
        qemu_log_mask(LOG_UNIMP,
                      "bl808_sec_eng: AES hardware key mode %u unsupported\n",
                      key_mode);
        return false;
    }
}

static void bl808_sec_eng_build_iv_regs(BL808SecEngState *s, uint32_t ctrl,
                                        uint8_t iv[16])
{
    QCryptoCipherMode mode;

    if (!bl808_sec_eng_aes_mode(ctrl, &mode)) {
        memset(iv, 0, 16);
        return;
    }

    if (mode == QCRYPTO_CIPHER_MODE_XTS) {
        for (size_t i = 0; i < 4; i++) {
            stl_be_p(iv + i * 4,
                     s->regs[(SEC_ENG_SE_AES_0_IV_3_OFFSET / 4) - i]);
        }
    } else {
        for (size_t i = 0; i < 4; i++) {
            stl_le_p(iv + i * 4, s->regs[SEC_ENG_SE_AES_0_IV_0_OFFSET / 4 + i]);
        }
    }
}

static bool bl808_sec_eng_build_aes_link_key(hwaddr link, bool xts,
                                             uint32_t key_mode, uint8_t *key,
                                             size_t *key_len,
                                             QCryptoCipherAlgo *alg)
{
    size_t key_part_len;

    if (xts) {
        switch (key_mode) {
        case 0:
        case 3:
            *alg = QCRYPTO_CIPHER_ALGO_AES_128;
            key_part_len = 16;
            break;
        case 1:
            *alg = QCRYPTO_CIPHER_ALGO_AES_256;
            key_part_len = 32;
            break;
        case 2:
            *alg = QCRYPTO_CIPHER_ALGO_AES_192;
            key_part_len = 24;
            break;
        default:
            qemu_log_mask(LOG_UNIMP,
                          "bl808_sec_eng: AES link XTS key mode %u unsupported\n",
                          key_mode);
            return false;
        }

        *key_len = key_part_len * 2;
        for (size_t i = 0; i < DIV_ROUND_UP(key_part_len, 4); i++) {
            stl_be_p(key + i * 4, bl808_sec_eng_ldl(link + 28 + i * 4));
            stl_be_p(key + key_part_len + i * 4,
                     bl808_sec_eng_ldl(link + 64 + i * 4));
        }
        return true;
    }

    switch (key_mode) {
    case 0:
        *alg = QCRYPTO_CIPHER_ALGO_AES_128;
        *key_len = 16;
        break;
    case 1:
        *alg = QCRYPTO_CIPHER_ALGO_AES_256;
        *key_len = 32;
        break;
    case 2:
        *alg = QCRYPTO_CIPHER_ALGO_AES_192;
        *key_len = 24;
        break;
    default:
        return false;
    }

    for (size_t i = 0; i < DIV_ROUND_UP(*key_len, 4); i++) {
        stl_be_p(key + i * 4, bl808_sec_eng_ldl(link + 28 + i * 4));
    }
    return true;
}

static void bl808_sec_eng_xts_mul_x(uint8_t tweak[16])
{
    uint8_t carry_in = 0;
    uint8_t carry_out = 0;

    for (size_t i = 0; i < 16; i++) {
        carry_out = tweak[i] >> 7;
        tweak[i] = (tweak[i] << 1) | carry_in;
        carry_in = carry_out;
    }
    if (carry_out) {
        tweak[0] ^= 0x87;
    }
}

static void bl808_sec_eng_xts_inc_unit(uint8_t unit_iv[16])
{
    for (size_t i = 0; i < 16; i++) {
        unit_iv[i]++;
        if (unit_iv[i] != 0) {
            break;
        }
    }
}

static bool bl808_sec_eng_run_aes_crypt(uint32_t ctrl, hwaddr src, hwaddr dst,
                                        const uint8_t *key, size_t key_len,
                                        QCryptoCipherAlgo alg,
                                        const uint8_t iv[16],
                                        uint16_t xts_unit_len,
                                        bool xts_single_unit,
                                        size_t data_len)
{
    g_autoptr(QCryptoCipher) cipher = NULL;
    g_autofree uint8_t *in = NULL;
    g_autofree uint8_t *out = NULL;
    QCryptoCipherMode mode;
    Error *local_err = NULL;

    if (!bl808_sec_eng_aes_mode(ctrl, &mode)) {
        return false;
    }

    if (mode == QCRYPTO_CIPHER_MODE_CTR) {
        uint8_t counter[16];
        uint8_t stream[16];

        if (!qcrypto_cipher_supports(alg, QCRYPTO_CIPHER_MODE_ECB)) {
            qemu_log_mask(LOG_UNIMP,
                          "bl808_sec_eng: AES CTR requires ECB cipher support\n");
            return false;
        }

        cipher = qcrypto_cipher_new(alg, QCRYPTO_CIPHER_MODE_ECB, key, key_len,
                                    &local_err);
        if (!cipher) {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "bl808_sec_eng: AES CTR init failed: %s\n",
                          error_get_pretty(local_err));
            error_free(local_err);
            return false;
        }

        in = bl808_sec_eng_read_guest(src, data_len);
        out = g_new0(uint8_t, data_len);
        memcpy(counter, iv, sizeof(counter));

        for (size_t offset = 0; offset < data_len; offset += sizeof(stream)) {
            if (qcrypto_cipher_encrypt(cipher, counter, stream, sizeof(stream),
                                       &local_err) < 0) {
                qemu_log_mask(LOG_GUEST_ERROR,
                              "bl808_sec_eng: AES CTR keystream failed: %s\n",
                              error_get_pretty(local_err));
                error_free(local_err);
                return false;
            }

            for (size_t i = 0; i < sizeof(stream) && offset + i < data_len; i++) {
                out[offset + i] = in[offset + i] ^ stream[i];
            }

            for (int i = sizeof(counter) - 1; i >= 0; i--) {
                counter[i]++;
                if (counter[i] != 0) {
                    break;
                }
            }
        }

        cpu_physical_memory_write(dst, out, data_len);
        return true;
    }

    if (mode == QCRYPTO_CIPHER_MODE_XTS) {
        g_autoptr(QCryptoCipher) crypt_cipher = NULL;
        g_autoptr(QCryptoCipher) tweak_cipher = NULL;
        uint8_t unit_iv[16];
        uint8_t tweak[16];
        Error *crypt_err = NULL;
        size_t key_part_len = key_len / 2;
        size_t offset = 0;
        size_t total_blocks = data_len / 16;
        size_t unit_blocks = xts_unit_len ? xts_unit_len : total_blocks;

        if ((key_len & 1) != 0 || key_part_len == 0 ||
            !qcrypto_cipher_supports(alg, QCRYPTO_CIPHER_MODE_ECB)) {
            qemu_log_mask(LOG_UNIMP,
                          "bl808_sec_eng: AES XTS requires ECB cipher support\n");
            return false;
        }

        crypt_cipher = qcrypto_cipher_new(alg, QCRYPTO_CIPHER_MODE_ECB,
                                          key, key_part_len, &local_err);
        if (!crypt_cipher) {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "bl808_sec_eng: AES XTS data-key init failed: %s\n",
                          error_get_pretty(local_err));
            error_free(local_err);
            return false;
        }

        tweak_cipher = qcrypto_cipher_new(alg, QCRYPTO_CIPHER_MODE_ECB,
                                          key + key_part_len, key_part_len,
                                          &crypt_err);
        if (!tweak_cipher) {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "bl808_sec_eng: AES XTS tweak-key init failed: %s\n",
                          error_get_pretty(crypt_err));
            error_free(crypt_err);
            return false;
        }

        in = bl808_sec_eng_read_guest(src, data_len);
        out = g_new0(uint8_t, data_len);
        memcpy(unit_iv, iv, sizeof(unit_iv));

        while (offset < data_len) {
            size_t blocks_this_unit = xts_single_unit ? total_blocks :
                                      MIN(unit_blocks, (data_len - offset) / 16);

            memcpy(tweak, unit_iv, sizeof(tweak));
            if (qcrypto_cipher_encrypt(tweak_cipher, tweak, tweak, sizeof(tweak),
                                       &crypt_err) < 0) {
                qemu_log_mask(LOG_GUEST_ERROR,
                              "bl808_sec_eng: AES XTS initial tweak failed: %s\n",
                              error_get_pretty(crypt_err));
                error_free(crypt_err);
                return false;
            }

            for (size_t block_idx = 0; block_idx < blocks_this_unit; block_idx++) {
                uint8_t block[16];
                uint8_t crypt[16];

                for (size_t i = 0; i < sizeof(block); i++) {
                    block[i] = in[offset + i] ^ tweak[i];
                }

                if (ctrl & SEC_ENG_SE_AES_0_DEC_EN) {
                    if (qcrypto_cipher_decrypt(crypt_cipher, block, crypt,
                                               sizeof(crypt), &crypt_err) < 0) {
                        qemu_log_mask(LOG_GUEST_ERROR,
                                      "bl808_sec_eng: AES XTS decrypt failed: %s\n",
                                      error_get_pretty(crypt_err));
                        error_free(crypt_err);
                        return false;
                    }
                } else {
                    if (qcrypto_cipher_encrypt(crypt_cipher, block, crypt,
                                               sizeof(crypt), &crypt_err) < 0) {
                        qemu_log_mask(LOG_GUEST_ERROR,
                                      "bl808_sec_eng: AES XTS encrypt failed: %s\n",
                                      error_get_pretty(crypt_err));
                        error_free(crypt_err);
                        return false;
                    }
                }

                for (size_t i = 0; i < sizeof(block); i++) {
                    out[offset + i] = crypt[i] ^ tweak[i];
                }

                offset += 16;
                if (block_idx + 1 != blocks_this_unit) {
                    bl808_sec_eng_xts_mul_x(tweak);
                }
            }

            if (!xts_single_unit && offset < data_len) {
                bl808_sec_eng_xts_inc_unit(unit_iv);
            }
        }

        cpu_physical_memory_write(dst, out, data_len);
        return true;
    }

    if (!qcrypto_cipher_supports(alg, mode)) {
        qemu_log_mask(LOG_UNIMP,
                      "bl808_sec_eng: AES alg/mode unsupported by QEMU\n");
        return false;
    }

    cipher = qcrypto_cipher_new(alg, mode, key, key_len, &local_err);
    if (!cipher) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sec_eng: AES init failed: %s\n",
                      error_get_pretty(local_err));
        error_free(local_err);
        return false;
    }

    if (mode != QCRYPTO_CIPHER_MODE_ECB &&
        qcrypto_cipher_setiv(cipher, iv, 16, &local_err) < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sec_eng: AES IV set failed: %s\n",
                      error_get_pretty(local_err));
        error_free(local_err);
        return false;
    }

    in = bl808_sec_eng_read_guest(src, data_len);
    out = g_new0(uint8_t, data_len);
    if (ctrl & SEC_ENG_SE_AES_0_DEC_EN) {
        if (qcrypto_cipher_decrypt(cipher, in, out, data_len, &local_err) < 0) {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "bl808_sec_eng: AES decrypt failed: %s\n",
                          error_get_pretty(local_err));
            error_free(local_err);
            return false;
        }
    } else {
        if (qcrypto_cipher_encrypt(cipher, in, out, data_len, &local_err) < 0) {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "bl808_sec_eng: AES encrypt failed: %s\n",
                          error_get_pretty(local_err));
            error_free(local_err);
            return false;
        }
    }

    cpu_physical_memory_write(dst, out, data_len);
    return true;
}

static void bl808_sec_eng_complete_aes(BL808SecEngState *s, uint32_t ctrl)
{
    s->regs[SEC_ENG_SE_AES_0_CTRL_OFFSET / 4] =
        ctrl & ~SEC_ENG_SE_AES_0_BUSY & ~SEC_ENG_SE_AES_0_TRIG_1T;
    s->regs[SEC_ENG_SE_AES_0_CTRL_OFFSET / 4] |= SEC_ENG_SE_AES_0_INT;
    s->regs[SEC_ENG_SE_AES_0_STATUS_OFFSET / 4] = 0;
    bl808_sec_eng_update_irq(s);
}

static void bl808_sec_eng_run_aes(BL808SecEngState *s, uint32_t ctrl)
{
    uint8_t key[64] = { 0 };
    uint8_t iv[16];
    size_t key_len = 0;
    QCryptoCipherAlgo alg;
    hwaddr src;
    hwaddr dst;
    size_t data_len;
    uint16_t xts_unit_len = 0;
    bool xts_single_unit = false;

    if (ctrl & SEC_ENG_SE_AES_0_LINK_MODE) {
        hwaddr link = s->regs[SEC_ENG_SE_AES_0_LINK_OFFSET / 4];
        uint32_t link_ctrl = bl808_sec_eng_ldl(link);
        uint32_t block_mode = (link_ctrl >> 12) & 0x3;
        uint32_t key_mode = (link_ctrl >> 3) & 0x3;
        bool xts = block_mode == 3;
        QCryptoCipherMode mode;

        ctrl = (ctrl & ~(SEC_ENG_SE_AES_0_BLOCK_MODE_MASK |
                         SEC_ENG_SE_AES_0_MODE_MASK |
                         SEC_ENG_SE_AES_0_DEC_EN |
                         SEC_ENG_SE_AES_0_MSG_LEN_MASK)) |
               ((block_mode << SEC_ENG_SE_AES_0_BLOCK_MODE_SHIFT) &
                SEC_ENG_SE_AES_0_BLOCK_MODE_MASK) |
               ((key_mode << SEC_ENG_SE_AES_0_MODE_SHIFT) &
                SEC_ENG_SE_AES_0_MODE_MASK) |
               ((link_ctrl & BIT(5)) ? SEC_ENG_SE_AES_0_DEC_EN : 0) |
               (link_ctrl & SEC_ENG_SE_AES_0_MSG_LEN_MASK);

        if (!bl808_sec_eng_aes_mode(ctrl, &mode)) {
            bl808_sec_eng_complete_aes(s, ctrl);
            return;
        }
        if (link_ctrl & SEC_ENG_SE_AES_0_HW_KEY_EN) {
            if (!bl808_sec_eng_build_aes_hw_key(s, ctrl, key, &key_len, &alg)) {
                bl808_sec_eng_complete_aes(s, ctrl);
                return;
            }
        } else {
            if (!bl808_sec_eng_build_aes_link_key(link, xts, key_mode, key,
                                                  &key_len, &alg)) {
                bl808_sec_eng_complete_aes(s, ctrl);
                return;
            }
        }
        for (size_t i = 0; i < 4; i++) {
            stl_be_p(iv + i * 4, bl808_sec_eng_ldl(link + 12 + i * 4));
        }
        if (xts) {
            xts_unit_len = bl808_sec_eng_ldl(link + 60) >> 16;
            xts_single_unit = (link_ctrl & BIT(15)) != 0;
        }

        src = bl808_sec_eng_ldl(link + 4);
        dst = bl808_sec_eng_ldl(link + 8);
    } else if (ctrl & SEC_ENG_SE_AES_0_HW_KEY_EN) {
        if (!bl808_sec_eng_build_aes_hw_key(s, ctrl, key, &key_len, &alg)) {
            bl808_sec_eng_complete_aes(s, ctrl);
            return;
        }
        bl808_sec_eng_build_iv_regs(s, ctrl, iv);
        if (((ctrl & SEC_ENG_SE_AES_0_BLOCK_MODE_MASK) >>
             SEC_ENG_SE_AES_0_BLOCK_MODE_SHIFT) == 3) {
            uint32_t sboot = s->regs[SEC_ENG_SE_AES_0_SBOOT_OFFSET / 4];

            xts_unit_len = (sboot >> 16) & 0xffffu;
            xts_single_unit = (sboot & BIT(15)) != 0;
        }
        src = s->regs[SEC_ENG_SE_AES_0_MSA_OFFSET / 4];
        dst = s->regs[SEC_ENG_SE_AES_0_MDA_OFFSET / 4];
    } else {
        if (!bl808_sec_eng_build_aes_key_regs(s, ctrl, key, &key_len, &alg)) {
            bl808_sec_eng_complete_aes(s, ctrl);
            return;
        }
        bl808_sec_eng_build_iv_regs(s, ctrl, iv);
        if (((ctrl & SEC_ENG_SE_AES_0_BLOCK_MODE_MASK) >>
             SEC_ENG_SE_AES_0_BLOCK_MODE_SHIFT) == 3) {
            uint32_t sboot = s->regs[SEC_ENG_SE_AES_0_SBOOT_OFFSET / 4];

            xts_unit_len = (sboot >> 16) & 0xffffu;
            xts_single_unit = (sboot & BIT(15)) != 0;
        }
        src = s->regs[SEC_ENG_SE_AES_0_MSA_OFFSET / 4];
        dst = s->regs[SEC_ENG_SE_AES_0_MDA_OFFSET / 4];
    }

    data_len = ((ctrl & SEC_ENG_SE_AES_0_MSG_LEN_MASK) >>
                SEC_ENG_SE_AES_0_MSG_LEN_SHIFT) * 16u;
    if (data_len == 0) {
        bl808_sec_eng_complete_aes(s, ctrl);
        return;
    }

    bl808_sec_eng_run_aes_crypt(ctrl, src, dst, key, key_len, alg, iv,
                                xts_unit_len, xts_single_unit, data_len);
    bl808_sec_eng_complete_aes(s, ctrl);
}

static uint32_t bl808_sec_eng_rand32(BL808SecEngState *s)
{
    uint64_t x = s->trng_state;

    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    s->trng_state = x;
    return (uint32_t)((x * UINT64_C(2685821657736338717)) >> 32);
}

static void bl808_sec_eng_run_trng(BL808SecEngState *s, uint32_t ctrl)
{
    for (size_t i = 0; i < 8; i++) {
        s->regs[SEC_ENG_SE_TRNG_0_DOUT_0_OFFSET / 4 + i] =
            bl808_sec_eng_rand32(s);
    }
    s->regs[SEC_ENG_SE_TRNG_0_STATUS_OFFSET / 4] = 1;
    s->regs[SEC_ENG_SE_TRNG_0_CTRL_0_OFFSET / 4] =
        (ctrl & ~(SEC_ENG_SE_TRNG_0_BUSY | SEC_ENG_SE_TRNG_0_TRIG_1T)) |
        SEC_ENG_SE_TRNG_0_INT;
    bl808_sec_eng_update_irq(s);
}

static bool bl808_sec_eng_run_gmac_link(BL808SecEngState *s)
{
#ifdef CONFIG_GNUTLS_CRYPTO
    hwaddr link_addr = s->regs[SEC_ENG_SE_GMAC_0_LCA_OFFSET / 4];
    uint32_t link_ctrl = bl808_sec_eng_ldl(link_addr);
    hwaddr src = bl808_sec_eng_ldl(link_addr + 4);
    size_t data_len = ((link_ctrl >> 16) & 0xffffu) * 16u;
    uint8_t key[16];
    uint8_t tag[16] = { 0 };
    uint8_t nonce[16] = { 0 };
    size_t nonce_len = gnutls_mac_get_nonce_size(GNUTLS_MAC_AES_GMAC_128);
    gnutls_hmac_hd_t hmac = NULL;
    int ret = GNUTLS_E_SUCCESS;
    bool ok = false;
    g_autofree uint8_t *data = NULL;

    for (size_t i = 0; i < 4; i++) {
        stl_le_p(key + i * 4, bl808_sec_eng_ldl(link_addr + 8 + i * 4));
    }
    data = bl808_sec_eng_read_guest(src, data_len);

    if (nonce_len > sizeof(nonce)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sec_eng: GMAC nonce length %zu too large\n",
                      nonce_len);
        goto out;
    }

    ret = gnutls_hmac_init(&hmac, GNUTLS_MAC_AES_GMAC_128, key, sizeof(key));
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sec_eng: GMAC init failed: %s\n",
                      gnutls_strerror(ret));
        goto out;
    }

    gnutls_hmac_set_nonce(hmac, nonce, nonce_len);
    ret = gnutls_hmac(hmac, data, data_len);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sec_eng: GMAC update failed: %s\n",
                      gnutls_strerror(ret));
        goto out;
    }

    gnutls_hmac_output(hmac, tag);
    cpu_physical_memory_write(link_addr + 0x18, tag, sizeof(tag));
    ok = true;

out:
    if (hmac) {
        gnutls_hmac_deinit(hmac, NULL);
    }
    if (!ok) {
        cpu_physical_memory_write(link_addr + 0x18, tag, sizeof(tag));
    }
    return ok;
#else
    qemu_log_mask(LOG_UNIMP,
                  "bl808_sec_eng: SEC_GMAC requires GnuTLS crypto backend\n");
    return false;
#endif
}

static uint64_t bl808_sec_eng_read(void *opaque, hwaddr offset, unsigned size)
{
    BL808SecEngState *s = opaque;

    if (size != 4) {
        return 0;
    }
    if ((offset & 3) || offset >= BL808_SEC_ENG_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sec_eng: bad read offset 0x%" HWADDR_PRIx "\n",
                      offset);
        return 0;
    }

    return s->regs[offset / 4];
}

static void bl808_sec_eng_write_sha(BL808SecEngState *s, uint32_t value)
{
    uint32_t ctrl = s->regs[SEC_ENG_SE_SHA_0_CTRL_OFFSET / 4];

    ctrl &= ~(SEC_ENG_SE_SHA_0_MODE_MASK | SEC_ENG_SE_SHA_0_EN |
              SEC_ENG_SE_SHA_0_HASH_SEL | SEC_ENG_SE_SHA_0_INT_MASK |
              SEC_ENG_SE_SHA_0_MODE_EXT_MASK | SEC_ENG_SE_SHA_0_LINK_MODE |
              SEC_ENG_SE_SHA_0_MSG_LEN_MASK);
    ctrl |= value & (SEC_ENG_SE_SHA_0_MODE_MASK | SEC_ENG_SE_SHA_0_EN |
                     SEC_ENG_SE_SHA_0_HASH_SEL | SEC_ENG_SE_SHA_0_INT_MASK |
                     SEC_ENG_SE_SHA_0_MODE_EXT_MASK |
                     SEC_ENG_SE_SHA_0_LINK_MODE |
                     SEC_ENG_SE_SHA_0_MSG_LEN_MASK);
    if (value & SEC_ENG_SE_SHA_0_INT_CLR_1T) {
        ctrl &= ~SEC_ENG_SE_SHA_0_INT;
    }
    if (value & SEC_ENG_SE_SHA_0_INT_SET_1T) {
        ctrl |= SEC_ENG_SE_SHA_0_INT;
    }
    if (value & SEC_ENG_SE_SHA_0_TRIG_1T) {
        ctrl |= SEC_ENG_SE_SHA_0_BUSY;
        s->regs[SEC_ENG_SE_SHA_0_CTRL_OFFSET / 4] = ctrl;
        bl808_sec_eng_run_sha(s, ctrl);
        return;
    }

    ctrl &= ~(SEC_ENG_SE_SHA_0_BUSY | SEC_ENG_SE_SHA_0_TRIG_1T);
    s->regs[SEC_ENG_SE_SHA_0_CTRL_OFFSET / 4] = ctrl;
    bl808_sec_eng_update_irq(s);
}

static void bl808_sec_eng_write_aes(BL808SecEngState *s, uint32_t value)
{
    uint32_t ctrl = s->regs[SEC_ENG_SE_AES_0_CTRL_OFFSET / 4];

    ctrl &= ~(SEC_ENG_SE_AES_0_EN | SEC_ENG_SE_AES_0_MODE_MASK |
              SEC_ENG_SE_AES_0_DEC_EN | SEC_ENG_SE_AES_0_HW_KEY_EN |
              SEC_ENG_SE_AES_0_INT_MASK | SEC_ENG_SE_AES_0_BLOCK_MODE_MASK |
              SEC_ENG_SE_AES_0_IV_SEL | SEC_ENG_SE_AES_0_LINK_MODE |
              SEC_ENG_SE_AES_0_MSG_LEN_MASK);
    ctrl |= value & (SEC_ENG_SE_AES_0_EN | SEC_ENG_SE_AES_0_MODE_MASK |
                     SEC_ENG_SE_AES_0_DEC_EN | SEC_ENG_SE_AES_0_HW_KEY_EN |
                     SEC_ENG_SE_AES_0_INT_MASK |
                     SEC_ENG_SE_AES_0_BLOCK_MODE_MASK |
                     SEC_ENG_SE_AES_0_IV_SEL | SEC_ENG_SE_AES_0_LINK_MODE |
                     SEC_ENG_SE_AES_0_MSG_LEN_MASK);
    if (value & SEC_ENG_SE_AES_0_INT_CLR_1T) {
        ctrl &= ~SEC_ENG_SE_AES_0_INT;
    }
    if (value & SEC_ENG_SE_AES_0_INT_SET_1T) {
        ctrl |= SEC_ENG_SE_AES_0_INT;
    }
    if (value & SEC_ENG_SE_AES_0_TRIG_1T) {
        ctrl |= SEC_ENG_SE_AES_0_BUSY;
        s->regs[SEC_ENG_SE_AES_0_CTRL_OFFSET / 4] = ctrl;
        bl808_sec_eng_run_aes(s, ctrl);
        return;
    }

    ctrl &= ~(SEC_ENG_SE_AES_0_BUSY | SEC_ENG_SE_AES_0_TRIG_1T);
    s->regs[SEC_ENG_SE_AES_0_CTRL_OFFSET / 4] = ctrl;
    bl808_sec_eng_update_irq(s);
}

static void bl808_sec_eng_write_trng(BL808SecEngState *s, uint32_t value)
{
    uint32_t ctrl = s->regs[SEC_ENG_SE_TRNG_0_CTRL_0_OFFSET / 4];

    ctrl &= ~(SEC_ENG_SE_TRNG_0_EN | SEC_ENG_SE_TRNG_0_INT_MASK);
    ctrl |= value & (SEC_ENG_SE_TRNG_0_EN | SEC_ENG_SE_TRNG_0_INT_MASK);
    if (value & SEC_ENG_SE_TRNG_0_INT_CLR_1T) {
        ctrl &= ~SEC_ENG_SE_TRNG_0_INT;
    }
    if (value & SEC_ENG_SE_TRNG_0_INT_SET_1T) {
        ctrl |= SEC_ENG_SE_TRNG_0_INT;
    }
    if (value & SEC_ENG_SE_TRNG_0_DOUT_CLR_1T) {
        memset(&s->regs[SEC_ENG_SE_TRNG_0_DOUT_0_OFFSET / 4], 0,
               8 * sizeof(uint32_t));
    }
    if ((value & SEC_ENG_SE_TRNG_0_TRIG_1T) && (ctrl & SEC_ENG_SE_TRNG_0_EN)) {
        ctrl |= SEC_ENG_SE_TRNG_0_BUSY;
        s->regs[SEC_ENG_SE_TRNG_0_CTRL_0_OFFSET / 4] = ctrl;
        bl808_sec_eng_run_trng(s, ctrl);
        return;
    }

    ctrl &= ~(SEC_ENG_SE_TRNG_0_BUSY | SEC_ENG_SE_TRNG_0_TRIG_1T);
    s->regs[SEC_ENG_SE_TRNG_0_CTRL_0_OFFSET / 4] = ctrl;
    bl808_sec_eng_update_irq(s);
}

static void bl808_sec_eng_write_pka(BL808SecEngState *s, uint32_t value)
{
    uint32_t ctrl = s->regs[SEC_ENG_SE_PKA_0_CTRL_0_OFFSET / 4];

    ctrl &= ~(SEC_ENG_SE_PKA_0_EN | SEC_ENG_SE_PKA_0_INT_MASK |
              (0xffffu << 16));
    ctrl |= value & (SEC_ENG_SE_PKA_0_EN | SEC_ENG_SE_PKA_0_INT_MASK |
                     (0xffffu << 16));
    if (value & SEC_ENG_SE_PKA_0_DONE_CLR_1T) {
        ctrl &= ~SEC_ENG_SE_PKA_0_DONE;
    }
    if (value & SEC_ENG_SE_PKA_0_INT_CLR_1T) {
        ctrl &= ~SEC_ENG_SE_PKA_0_INT;
    }
    if (value & SEC_ENG_SE_PKA_0_INT_SET) {
        ctrl |= SEC_ENG_SE_PKA_0_INT;
    }
    if (value & SEC_ENG_SE_PKA_0_EN) {
        ctrl |= SEC_ENG_SE_PKA_0_DONE;
    }
    ctrl &= ~SEC_ENG_SE_PKA_0_BUSY;
    s->regs[SEC_ENG_SE_PKA_0_CTRL_0_OFFSET / 4] = ctrl;
    bl808_sec_eng_update_irq(s);
}

static void bl808_sec_eng_write_cdet(BL808SecEngState *s, uint32_t value)
{
    uint32_t ctrl = s->regs[SEC_ENG_SE_CDET_0_CTRL_0_OFFSET / 4];

    ctrl &= ~(SEC_ENG_SE_CDET_0_EN | SEC_ENG_SE_CDET_0_INT_MASK |
              SEC_ENG_SE_CDET_0_MODE | (0x1fu << 3));
    ctrl |= value & (SEC_ENG_SE_CDET_0_EN | SEC_ENG_SE_CDET_0_INT_MASK |
                     SEC_ENG_SE_CDET_0_MODE | (0x1fu << 3));
    if (value & SEC_ENG_SE_CDET_0_INT_CLR) {
        ctrl &= ~SEC_ENG_SE_CDET_0_INT;
    }
    if (value & SEC_ENG_SE_CDET_0_INT_SET) {
        ctrl |= SEC_ENG_SE_CDET_0_INT;
    }
    ctrl &= ~SEC_ENG_SE_CDET_0_BUSY;
    if (value & SEC_ENG_SE_CDET_0_EN) {
        ctrl |= SEC_ENG_SE_CDET_0_INT;
    }
    s->regs[SEC_ENG_SE_CDET_0_CTRL_0_OFFSET / 4] = ctrl;
    bl808_sec_eng_update_irq(s);
}

static void bl808_sec_eng_write_gmac(BL808SecEngState *s, uint32_t value)
{
    uint32_t ctrl = s->regs[SEC_ENG_SE_GMAC_0_CTRL_0_OFFSET / 4];

    ctrl &= ~(SEC_ENG_SE_GMAC_0_EN | SEC_ENG_SE_GMAC_0_INT_MASK | BIT(12) |
              BIT(13) | BIT(14));
    ctrl |= value & (SEC_ENG_SE_GMAC_0_EN | SEC_ENG_SE_GMAC_0_INT_MASK |
                     BIT(12) | BIT(13) | BIT(14));
    if (value & SEC_ENG_SE_GMAC_0_INT_CLR_1T) {
        ctrl &= ~SEC_ENG_SE_GMAC_0_INT;
    }
    if (value & SEC_ENG_SE_GMAC_0_INT_SET_1T) {
        ctrl |= SEC_ENG_SE_GMAC_0_INT;
    }
    if ((value & SEC_ENG_SE_GMAC_0_TRIG_1T) && (ctrl & SEC_ENG_SE_GMAC_0_EN)) {
        bl808_sec_eng_run_gmac_link(s);
        ctrl |= SEC_ENG_SE_GMAC_0_INT;
    }
    ctrl &= ~(SEC_ENG_SE_GMAC_0_BUSY | SEC_ENG_SE_GMAC_0_TRIG_1T);
    s->regs[SEC_ENG_SE_GMAC_0_CTRL_0_OFFSET / 4] = ctrl;
    s->regs[SEC_ENG_SE_GMAC_0_STATUS_OFFSET / 4] = 0;
    bl808_sec_eng_update_irq(s);
}

static void bl808_sec_eng_write(void *opaque, hwaddr offset, uint64_t value,
                                unsigned size)
{
    BL808SecEngState *s = opaque;
    uint32_t val = (uint32_t)value;

    if (size != 4) {
        return;
    }
    if ((offset & 3) || offset >= BL808_SEC_ENG_REG_SIZE) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "bl808_sec_eng: bad write offset 0x%" HWADDR_PRIx
                      " = 0x%" PRIx64 "\n", offset, value);
        return;
    }

    switch (offset) {
    case SEC_ENG_SE_SHA_0_CTRL_OFFSET:
        bl808_sec_eng_write_sha(s, val);
        return;
    case SEC_ENG_SE_AES_0_CTRL_OFFSET:
        bl808_sec_eng_write_aes(s, val);
        return;
    case SEC_ENG_SE_TRNG_0_CTRL_0_OFFSET:
        bl808_sec_eng_write_trng(s, val);
        return;
    case SEC_ENG_SE_PKA_0_CTRL_0_OFFSET:
        bl808_sec_eng_write_pka(s, val);
        return;
    case SEC_ENG_SE_CDET_0_CTRL_0_OFFSET:
        bl808_sec_eng_write_cdet(s, val);
        return;
    case SEC_ENG_SE_GMAC_0_CTRL_0_OFFSET:
        bl808_sec_eng_write_gmac(s, val);
        return;
    case SEC_ENG_SE_SHA_0_CTRL_PROT_OFFSET:
    case SEC_ENG_SE_AES_0_CTRL_PROT_OFFSET:
    case SEC_ENG_SE_TRNG_0_CTRL_PROT_OFFSET:
    case SEC_ENG_SE_PKA_0_CTRL_PROT_OFFSET:
    case SEC_ENG_SE_CDET_0_CTRL_PROT_OFFSET:
    case SEC_ENG_SE_GMAC_0_CTRL_PROT_OFFSET:
        bl808_sec_eng_set_owner(s, offset, val);
        bl808_sec_eng_update_irq(s);
        return;
    default:
        break;
    }

    s->regs[offset / 4] = val;
}

static const MemoryRegionOps bl808_sec_eng_ops = {
    .read = bl808_sec_eng_read,
    .write = bl808_sec_eng_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 4,
    .impl.max_access_size = 4,
};

static void bl808_sec_eng_reset(DeviceState *dev)
{
    BL808SecEngState *s = BL808_SEC_ENG(dev);

    memset(s->regs, 0, sizeof(s->regs));
    bl808_sec_eng_sha_accum_reset(s);
    s->regs[SEC_ENG_SE_SHA_0_STATUS_OFFSET / 4] = 0x41;
    s->regs[SEC_ENG_SE_SHA_0_ENDIAN_OFFSET / 4] = 0x1;
    s->regs[SEC_ENG_SE_AES_0_ENDIAN_OFFSET / 4] = 0x1f;
    s->regs[SEC_ENG_SE_AES_0_SBOOT_OFFSET / 4] = 2u << 16;
    s->regs[SEC_ENG_SE_SHA_0_CTRL_PROT_OFFSET / 4] = 0x6;
    s->regs[SEC_ENG_SE_AES_0_CTRL_PROT_OFFSET / 4] = 0x6;
    s->regs[SEC_ENG_SE_TRNG_0_CTRL_PROT_OFFSET / 4] = 0x6;
    s->regs[SEC_ENG_SE_PKA_0_CTRL_PROT_OFFSET / 4] = 0x6;
    s->regs[SEC_ENG_SE_CDET_0_CTRL_PROT_OFFSET / 4] = 0x7;
    s->regs[SEC_ENG_SE_GMAC_0_CTRL_PROT_OFFSET / 4] = 0x6;
    bl808_sec_eng_update_ctrl_prot(s);
    s->trng_state = UINT64_C(0x8081b10b1e5eed5);
    bl808_sec_eng_update_irq(s);
}

static void bl808_sec_eng_init(Object *obj)
{
    BL808SecEngState *s = BL808_SEC_ENG(obj);
    SysBusDevice *sbd = SYS_BUS_DEVICE(obj);

    memory_region_init_io(&s->iomem, obj, &bl808_sec_eng_ops, s,
                          TYPE_BL808_SEC_ENG, BL808_SEC_ENG_REG_SIZE);
    sysbus_init_mmio(sbd, &s->iomem);
    sysbus_init_irq(sbd, &s->irq[BL808_SEC_ENG_IRQ_ID1_SHARED]);
    sysbus_init_irq(sbd, &s->irq[BL808_SEC_ENG_IRQ_ID0_SHARED]);
    sysbus_init_irq(sbd, &s->irq[BL808_SEC_ENG_IRQ_ID1_CDET]);
    sysbus_init_irq(sbd, &s->irq[BL808_SEC_ENG_IRQ_ID0_CDET]);
}

static void bl808_sec_eng_finalize(Object *obj)
{
    BL808SecEngState *s = BL808_SEC_ENG(obj);

    bl808_sec_eng_sha_accum_reset(s);
}

static void bl808_sec_eng_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_legacy_reset(dc, bl808_sec_eng_reset);
}

static const TypeInfo bl808_sec_eng_info = {
    .name = TYPE_BL808_SEC_ENG,
    .parent = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(BL808SecEngState),
    .instance_init = bl808_sec_eng_init,
    .instance_finalize = bl808_sec_eng_finalize,
    .class_init = bl808_sec_eng_class_init,
};

static void bl808_sec_eng_register_types(void)
{
    type_register_static(&bl808_sec_eng_info);
}

type_init(bl808_sec_eng_register_types)
