/*
 * BL808 M0 RAM-resident JTAG flash stub.
 *
 * OpenOCD loads this image into M0 RAM, then the host controls it through a
 * mailbox in the upper WRAM window. It only touches SPI NOR flash through the
 * SF controller; it does not access eFuse.
 */

#include <stdint.h>

#define STUB_ENTRY          0x22020000u
#define STUB_STACK          0x2204F000u
#define MAILBOX_BASE        0x2204C000u
#define DATA_BASE           0x2204C100u
#define DATA_MAX            0x00001000u

#define SF_CTRL_BASE        0x2000B000u
#define SF_CTRL_BUF         0x2000B600u
#define SF_CTRL_CFG1        (SF_CTRL_BASE + 0x04u)
#define SF_CTRL_IF_SAHB0    (SF_CTRL_BASE + 0x08u)
#define SF_CTRL_IF_SAHB1    (SF_CTRL_BASE + 0x0Cu)
#define SF_CTRL_IF_SAHB2    (SF_CTRL_BASE + 0x10u)

#define SF_CTRL1_OWNER_IAHB (1u << 28)
#define SF_CTRL1_IF_EN      (1u << 29)
#define SF_CTRL1_AHB2SIF_EN (1u << 30)

#define SAHB0_BUSY          (1u << 0)
#define SAHB0_TRIGGER       (1u << 1)
#define SAHB0_DATA_BYTES_SHIFT 2
#define SAHB0_ADDR_BYTES_SHIFT 17
#define SAHB0_CMD_BYTES_SHIFT 20
#define SAHB0_DATA_RW       (1u << 23)
#define SAHB0_DATA_EN       (1u << 24)
#define SAHB0_ADDR_EN       (1u << 26)
#define SAHB0_CMD_EN        (1u << 27)

#define FLASH_CMD_WRITE_EN  0x06u
#define FLASH_CMD_READ_SR1  0x05u
#define FLASH_CMD_READ      0x03u
#define FLASH_CMD_PAGE_PROG 0x02u
#define FLASH_CMD_SECTOR_ER 0x20u
#define FLASH_CMD_BLOCK64_ER 0xD8u
#define FLASH_CMD_READ_ID   0x9Fu

#define FLASH_PAGE_SIZE     256u
#define FLASH_SECTOR_SIZE   4096u
#define FLASH_BLOCK64_SIZE  65536u

#define MB_MAGIC            0x4A544746u /* "JTGF" */
#define MB_STATUS_READY     0x52454144u /* "READ" */
#define MB_STATUS_BUSY      0x42555359u /* "BUSY" */
#define MB_STATUS_DONE      0x444F4E45u /* "DONE" */
#define MB_STATUS_ERROR     0x45525221u /* "ERR!" */

#define CMD_NONE            0u
#define CMD_READ_ID         1u
#define CMD_ERASE           2u
#define CMD_WRITE_VERIFY    3u

#define ERR_OK              0u
#define ERR_BAD_COMMAND     1u
#define ERR_BAD_LENGTH      2u
#define ERR_CHECKSUM        3u
#define ERR_TIMEOUT         4u
#define ERR_VERIFY          5u

struct mailbox {
    volatile uint32_t magic;
    volatile uint32_t command;
    volatile uint32_t status;
    volatile uint32_t address;
    volatile uint32_t length;
    volatile uint32_t checksum;
    volatile uint32_t result;
    volatile uint32_t counter;
};

static inline volatile struct mailbox *mbox(void)
{
    return (volatile struct mailbox *)MAILBOX_BASE;
}

static inline volatile uint8_t *data_buf(void)
{
    return (volatile uint8_t *)DATA_BASE;
}

static inline uint32_t read32(uint32_t addr)
{
    return *(volatile uint32_t *)addr;
}

static inline void write32(uint32_t addr, uint32_t value)
{
    *(volatile uint32_t *)addr = value;
}

static void wait_cycles(uint32_t cycles)
{
    while (cycles--) {
        __asm__ volatile("nop");
    }
}

static int sf_wait_idle(uint32_t timeout)
{
    while (timeout--) {
        if ((read32(SF_CTRL_IF_SAHB0) & SAHB0_BUSY) == 0) {
            return 0;
        }
    }
    return -1;
}

static void sf_claim_sahb(void)
{
    uint32_t cfg1 = read32(SF_CTRL_CFG1);
    cfg1 &= ~(SF_CTRL1_OWNER_IAHB | SF_CTRL1_AHB2SIF_EN);
    cfg1 |= SF_CTRL1_IF_EN;
    write32(SF_CTRL_CFG1, cfg1);
}

static int sf_send_cmd(uint8_t cmd, uint32_t flash_addr, int has_addr,
                       uint32_t data_len, int data_write)
{
    uint32_t cmd0 = ((uint32_t)cmd) << 24;
    uint32_t cmd1 = 0;
    uint32_t sahb0 = SAHB0_CMD_EN | (0u << SAHB0_CMD_BYTES_SHIFT);

    if (has_addr) {
        cmd0 |= ((flash_addr >> 16) & 0xFFu) << 16;
        cmd0 |= ((flash_addr >> 8) & 0xFFu) << 8;
        cmd0 |= (flash_addr & 0xFFu);
        sahb0 |= SAHB0_ADDR_EN | (2u << SAHB0_ADDR_BYTES_SHIFT);
    }

    if (data_len != 0) {
        sahb0 |= SAHB0_DATA_EN | ((data_len - 1u) << SAHB0_DATA_BYTES_SHIFT);
        if (data_write) {
            sahb0 |= SAHB0_DATA_RW;
        }
    }

    if (sf_wait_idle(1000000u) != 0) {
        return -1;
    }
    sf_claim_sahb();
    write32(SF_CTRL_IF_SAHB0, read32(SF_CTRL_IF_SAHB0) & ~SAHB0_TRIGGER);
    write32(SF_CTRL_IF_SAHB1, cmd0);
    write32(SF_CTRL_IF_SAHB2, cmd1);
    write32(SF_CTRL_IF_SAHB0, sahb0);
    write32(SF_CTRL_IF_SAHB0, sahb0 | SAHB0_TRIGGER);
    return sf_wait_idle(1000000u);
}

static int flash_wait_ready(uint32_t timeout)
{
    while (timeout--) {
        if (sf_send_cmd((uint8_t)FLASH_CMD_READ_SR1, 0, 0, 1, 0) != 0) {
            return -1;
        }
        if ((read32(SF_CTRL_BUF) & 1u) == 0) {
            return 0;
        }
    }
    return -1;
}

static int flash_write_enable(void)
{
    return sf_send_cmd((uint8_t)FLASH_CMD_WRITE_EN, 0, 0, 0, 0);
}

static uint32_t flash_read_id(void)
{
    if (sf_send_cmd((uint8_t)FLASH_CMD_READ_ID, 0, 0, 3, 0) != 0) {
        return 0;
    }
    return read32(SF_CTRL_BUF) & 0x00FFFFFFu;
}

static int flash_erase_cmd(uint8_t cmd, uint32_t address, uint32_t timeout)
{
    if (flash_write_enable() != 0) {
        return -1;
    }
    if (sf_send_cmd(cmd, address, 1, 0, 0) != 0) {
        return -1;
    }
    return flash_wait_ready(timeout);
}

static int flash_erase_range(uint32_t address, uint32_t length)
{
    uint32_t start = address & ~(FLASH_SECTOR_SIZE - 1u);
    uint32_t end = (address + length + FLASH_SECTOR_SIZE - 1u) &
                   ~(FLASH_SECTOR_SIZE - 1u);
    uint32_t pos = start;

    while (pos < end) {
        if ((pos & (FLASH_BLOCK64_SIZE - 1u)) == 0 &&
            (end - pos) >= FLASH_BLOCK64_SIZE) {
            if (flash_erase_cmd((uint8_t)FLASH_CMD_BLOCK64_ER, pos, 20000000u) != 0) {
                return -1;
            }
            pos += FLASH_BLOCK64_SIZE;
        } else {
            if (flash_erase_cmd((uint8_t)FLASH_CMD_SECTOR_ER, pos, 5000000u) != 0) {
                return -1;
            }
            pos += FLASH_SECTOR_SIZE;
        }
        mbox()->counter = pos;
    }
    return 0;
}

static uint32_t checksum_data(uint32_t length)
{
    volatile uint8_t *buf = data_buf();
    uint32_t sum = 0;
    for (uint32_t i = 0; i < length; i++) {
        sum = (sum << 5) ^ (sum >> 27) ^ buf[i];
    }
    return sum;
}

static void copy_to_sf_buf(uint32_t offset, uint32_t length)
{
    volatile uint8_t *src = data_buf() + offset;
    for (uint32_t i = 0; i < length; i += 4) {
        uint32_t word = 0xFFFFFFFFu;
        uint32_t remain = length - i;
        if (remain > 4u) {
            remain = 4u;
        }
        for (uint32_t j = 0; j < remain; j++) {
            word &= ~(0xFFu << (j * 8u));
            word |= ((uint32_t)src[i + j]) << (j * 8u);
        }
        write32(SF_CTRL_BUF + i, word);
    }
}

static int flash_read_compare(uint32_t address, uint32_t offset, uint32_t length)
{
    volatile uint8_t *expected = data_buf() + offset;

    for (uint32_t base = 0; base < length; base += FLASH_PAGE_SIZE) {
        uint32_t n = length - base;
        if (n > FLASH_PAGE_SIZE) {
            n = FLASH_PAGE_SIZE;
        }
        if (sf_send_cmd((uint8_t)FLASH_CMD_READ, address + base, 1, n, 0) != 0) {
            return -1;
        }
        for (uint32_t i = 0; i < n; i++) {
            uint32_t word = read32(SF_CTRL_BUF + (i & ~3u));
            uint8_t got = (uint8_t)(word >> ((i & 3u) * 8u));
            if (got != expected[base + i]) {
                mbox()->counter = ((uint32_t)expected[base + i] << 24) |
                                  ((uint32_t)got << 16) |
                                  ((base + i) & 0x0000FFFFu);
                return -1;
            }
        }
    }
    return 0;
}

static int flash_program_verify(uint32_t address, uint32_t length)
{
    uint32_t done = 0;
    if (length == 0 || length > DATA_MAX) {
        return ERR_BAD_LENGTH;
    }
    if (checksum_data(length) != mbox()->checksum) {
        return ERR_CHECKSUM;
    }

    while (done < length) {
        uint32_t page_off = (address + done) & (FLASH_PAGE_SIZE - 1u);
        uint32_t n = FLASH_PAGE_SIZE - page_off;
        if (n > length - done) {
            n = length - done;
        }
        if (flash_write_enable() != 0) {
            return ERR_TIMEOUT;
        }
        copy_to_sf_buf(done, n);
        if (sf_send_cmd((uint8_t)FLASH_CMD_PAGE_PROG, address + done, 1, n, 1) != 0) {
            return ERR_TIMEOUT;
        }
        if (flash_wait_ready(2000000u) != 0) {
            return ERR_TIMEOUT;
        }
        done += n;
        mbox()->counter = address + done;
    }

    if (flash_read_compare(address, 0, length) != 0) {
        return ERR_VERIFY;
    }
    return ERR_OK;
}

void main(void)
{
    volatile struct mailbox *mb = mbox();
    sf_claim_sahb();
    mb->magic = MB_MAGIC;
    mb->command = CMD_NONE;
    mb->result = ERR_OK;
    mb->counter = 0;
    mb->status = MB_STATUS_READY;

    for (;;) {
        uint32_t cmd = mb->command;
        if (cmd == CMD_NONE) {
            wait_cycles(1000u);
            continue;
        }

        mb->status = MB_STATUS_BUSY;
        mb->result = ERR_OK;
        mb->counter = 0;

        if (cmd == CMD_READ_ID) {
            mb->result = flash_read_id();
        } else if (cmd == CMD_ERASE) {
            if (mb->length == 0) {
                mb->result = ERR_BAD_LENGTH;
            } else if (flash_erase_range(mb->address, mb->length) != 0) {
                mb->result = ERR_TIMEOUT;
            }
        } else if (cmd == CMD_WRITE_VERIFY) {
            mb->result = flash_program_verify(mb->address, mb->length);
        } else {
            mb->result = ERR_BAD_COMMAND;
        }

        mb->command = CMD_NONE;
        mb->status = (mb->result == ERR_OK || cmd == CMD_READ_ID)
            ? MB_STATUS_DONE
            : MB_STATUS_ERROR;
    }
}

void _start(void) __attribute__((naked, section(".text.entry")));
void _start(void)
{
    __asm__ volatile(
        "csrci mstatus, 8\n"
        "li sp, %[stack]\n"
        "j main\n"
        :
        : [stack] "i" (STUB_STACK)
    );
}
