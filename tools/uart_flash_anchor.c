/*
 * BL808 M0 RAM-resident UART flash anchor.
 *
 * OpenOCD loads this image into M0 RAM after reset-halt, then the host streams
 * flash chunks over the normal UART0 console pins. The anchor only touches SPI
 * NOR flash through the SF controller; it does not access eFuse.
 */

#include <stdint.h>

#define ANCHOR_STACK        0x2204F000u
#define TRAP_INFO_BASE      0x2204C000u
#define DEBUG_INFO_BASE     0x2204C020u
#define DATA_BASE           0x2204C100u
#define DATA_MAX            0x00001000u

#define GLB_BASE            0x20000000u
#define HBN_BASE            0x2000F000u
#define GLB_UART_CFG0       (GLB_BASE + 0x150u)
#define GLB_UART_CFG1       (GLB_BASE + 0x154u)
#define GLB_UART_CFG2       (GLB_BASE + 0x158u)
#define GLB_SWRST_CFG2      (GLB_BASE + 0x548u)
#define GLB_CGEN_CFG1       (GLB_BASE + 0x584u)
#define HBN_GLB             (HBN_BASE + 0x030u)
#define GPIO_CFG_BASE       (GLB_BASE + 0x8C4u)

#define UART0_BASE          0x2000A000u
#define UART_UTX_CONFIG     0x00u
#define UART_URX_CONFIG     0x04u
#define UART_BIT_PRD        0x08u
#define UART_DATA_CONFIG    0x0Cu
#define UART_INT_MASK       0x24u
#define UART_FIFO_CONFIG0   0x80u
#define UART_FIFO_CONFIG1   0x84u
#define UART_FIFO_WDATA     0x88u
#define UART_FIFO_RDATA     0x8Cu

#define UART_UTX_EN         (1u << 0)
#define UART_UTX_FREERUN    (1u << 2)
#define UART_URX_EN         (1u << 0)
#define UART_DATA8          7u
#define UART_STOP1          1u
#define UART_TX_FREE_MASK   0x3Fu
#define UART_RX_COUNT_MASK  (0x3Fu << 8)
#define UART_TX_CLR         (1u << 2)
#define UART_RX_CLR         (1u << 3)
#define UART_SIG_DISABLED   0x0Fu
#define UART0_TX_SIGNAL     2u
#define UART0_RX_SIGNAL     3u
#define GPIO_UART_CFG       ((1u << 30) | (1u << 22) | (7u << 8) | \
                             (1u << 4) | (1u << 2) | (1u << 1) | \
                             (1u << 0))

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

#define REQ_MAGIC           0x31414655u /* "UFA1" */
#define REQ_GUARD           0x48535246u /* "FRSH" */
#define RESP_MAGIC          0x31524655u /* "UFR1" */

#define CMD_PING            0u
#define CMD_READ_ID         1u
#define CMD_ERASE           2u
#define CMD_WRITE_VERIFY    3u
#define CMD_REBOOT          4u

#define ERR_OK              0u
#define ERR_BAD_COMMAND     1u
#define ERR_BAD_LENGTH      2u
#define ERR_CHECKSUM        3u
#define ERR_TIMEOUT         4u
#define ERR_VERIFY          5u
#define ERR_BUSY            0xFFFFFFFFu

#ifndef UART_ANCHOR_BAUD
#define UART_ANCHOR_BAUD    230400u
#endif

struct request {
    uint32_t command;
    uint32_t address;
    uint32_t length;
    uint32_t header_checksum;
};

static inline uint32_t read32(uint32_t addr)
{
    return *(volatile uint32_t *)addr;
}

static inline void write32(uint32_t addr, uint32_t value)
{
    *(volatile uint32_t *)addr = value;
}

static inline void dcache_flush_all(void)
{
    __asm__ volatile("" ::: "memory");
}

static inline volatile uint8_t *data_buf(void)
{
    return (volatile uint8_t *)DATA_BASE;
}

static void debug_clear(void)
{
    for (uint32_t off = 0; off <= 0x20u; off += 4u) {
        write32(DEBUG_INFO_BASE + off, 0);
    }
}

static void uart_signal_select(uint32_t pin, uint32_t uart_func)
{
    uint32_t sig = pin % 12u;
    uint32_t cfg1 = read32(GLB_UART_CFG1);
    uint32_t cfg2 = read32(GLB_UART_CFG2);
    uint32_t func = uart_func & 0x0Fu;

    if (sig < 8u) {
        uint32_t shift = sig * 4u;
        cfg1 = (cfg1 & ~(0x0Fu << shift)) | (func << shift);
    } else {
        uint32_t shift = (sig - 8u) * 4u;
        cfg2 = (cfg2 & ~(0x0Fu << shift)) | (func << shift);
    }

    if (func != UART_SIG_DISABLED) {
        for (uint32_t i = 0; i < 8u; i++) {
            uint32_t shift = i * 4u;
            if (i != sig && ((cfg1 >> shift) & 0x0Fu) == func) {
                cfg1 = (cfg1 & ~(0x0Fu << shift)) |
                       (UART_SIG_DISABLED << shift);
            }
        }
        for (uint32_t i = 8u; i < 12u; i++) {
            uint32_t shift = (i - 8u) * 4u;
            if (i != sig && ((cfg2 >> shift) & 0x0Fu) == func) {
                cfg2 = (cfg2 & ~(0x0Fu << shift)) |
                       (UART_SIG_DISABLED << shift);
            }
        }
    }

    write32(GLB_UART_CFG1, cfg1);
    write32(GLB_UART_CFG2, cfg2);
}

static void uart0_init(uint32_t baud)
{
    uint32_t hbn;
    uint32_t cfg;
    uint32_t bit_prd = (40000000u / baud) - 1u;

    write32(GLB_CGEN_CFG1, read32(GLB_CGEN_CFG1) | (1u << 16));
    write32(HBN_GLB, read32(HBN_GLB) | (1u << 0));

    cfg = read32(GLB_UART_CFG0);
    cfg &= ~(1u << 4);
    cfg &= ~0x7u;
    write32(GLB_UART_CFG0, cfg);

    hbn = read32(HBN_GLB);
    hbn &= ~((1u << 2) | (1u << 15));
    hbn |= (1u << 15);
    write32(HBN_GLB, hbn);

    write32(GLB_UART_CFG0, read32(GLB_UART_CFG0) | (1u << 4));

    uart_signal_select(14u, UART0_TX_SIGNAL);
    uart_signal_select(15u, UART0_RX_SIGNAL);

    write32(GPIO_CFG_BASE + 14u * 4u, GPIO_UART_CFG);
    write32(GPIO_CFG_BASE + 15u * 4u, GPIO_UART_CFG);

    write32(UART0_BASE + UART_UTX_CONFIG, 0);
    write32(UART0_BASE + UART_URX_CONFIG, 0);
    write32(UART0_BASE + UART_BIT_PRD, (bit_prd << 16) | bit_prd);
    write32(UART0_BASE + UART_DATA_CONFIG, 0);
    write32(UART0_BASE + UART_FIFO_CONFIG0, UART_TX_CLR | UART_RX_CLR);
    write32(UART0_BASE + UART_FIFO_CONFIG1, (16u << 16) | (16u << 24));
    write32(UART0_BASE + UART_INT_MASK, 0xFFFFFFFFu);
    write32(UART0_BASE + UART_UTX_CONFIG,
            (UART_DATA8 << 8) | (UART_STOP1 << 11) |
            UART_UTX_FREERUN | UART_UTX_EN);
    write32(UART0_BASE + UART_URX_CONFIG, (UART_DATA8 << 8) | UART_URX_EN);
}

static uint32_t uart_tx_free(void)
{
    return read32(UART0_BASE + UART_FIFO_CONFIG1) & UART_TX_FREE_MASK;
}

static uint32_t uart_rx_count(void)
{
    return (read32(UART0_BASE + UART_FIFO_CONFIG1) & UART_RX_COUNT_MASK) >> 8;
}

static void uart_send_byte(uint8_t byte)
{
    while (uart_tx_free() == 0) {
        __asm__ volatile("nop");
    }
    write32(UART0_BASE + UART_FIFO_WDATA, (uint32_t)byte);
}

static uint8_t uart_recv_byte(void)
{
    while (uart_rx_count() == 0) {
        __asm__ volatile("nop");
    }
    return (uint8_t)(read32(UART0_BASE + UART_FIFO_RDATA) & 0xFFu);
}

static int uart_try_recv_byte(uint8_t *byte)
{
    if (uart_rx_count() == 0) {
        return 0;
    }
    *byte = (uint8_t)(read32(UART0_BASE + UART_FIFO_RDATA) & 0xFFu);
    return 1;
}

static void uart_send_string(const char *text)
{
    while (*text != '\0') {
        uart_send_byte((uint8_t)*text);
        text++;
    }
}

static void uart_send_u32(uint32_t value)
{
    uart_send_byte((uint8_t)(value & 0xFFu));
    uart_send_byte((uint8_t)((value >> 8) & 0xFFu));
    uart_send_byte((uint8_t)((value >> 16) & 0xFFu));
    uart_send_byte((uint8_t)((value >> 24) & 0xFFu));
}

static uint32_t uart_recv_u32(void)
{
    uint32_t value = 0;
    value |= (uint32_t)uart_recv_byte();
    value |= (uint32_t)uart_recv_byte() << 8;
    value |= (uint32_t)uart_recv_byte() << 16;
    value |= (uint32_t)uart_recv_byte() << 24;
    return value;
}

static struct request uart_recv_request(void)
{
    struct request req;
    uint32_t window = 0;
    uint32_t idle = 0;
    uint32_t guard = 0;
    do {
        uint8_t byte = 0;
        if (!uart_try_recv_byte(&byte)) {
            idle++;
            if (idle >= 2000000u) {
                uart_send_string("\r\nBL808-UART-FLASH-ANCHOR v1\r\n");
                idle = 0;
            }
            continue;
        }
        idle = 0;
        window = (window >> 8) | ((uint32_t)byte << 24);
    } while (window != REQ_MAGIC);
    guard = uart_recv_u32();
    if (guard != REQ_GUARD) {
        req.command = 0xFFFFFFFFu;
        req.address = 0;
        req.length = 0;
        req.header_checksum = 0;
        return req;
    }
    req.command = uart_recv_u32();
    req.address = uart_recv_u32();
    req.length = uart_recv_u32();
    req.header_checksum = uart_recv_u32();
    return req;
}

static void uart_send_response(uint32_t status, uint32_t result, uint32_t counter)
{
    uart_send_u32(RESP_MAGIC);
    uart_send_u32(status);
    uart_send_u32(result);
    uart_send_u32(counter);
}

static void delay_cycles(uint32_t count)
{
    while (count--) {
        __asm__ volatile("nop");
    }
}

static void reboot_chip(void)
{
    uint32_t value = read32(GLB_SWRST_CFG2);
    value &= ~(1u << 5);
    write32(GLB_SWRST_CFG2, value);
    delay_cycles(1000u);
    value |= (1u << 5);
    write32(GLB_SWRST_CFG2, value);
    delay_cycles(1000u);
    value &= ~(1u << 5);
    write32(GLB_SWRST_CFG2, value);
    for (;;) {
        __asm__ volatile("wfi");
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

static uint32_t checksum_header(uint32_t command, uint32_t address, uint32_t length)
{
    return ~(REQ_GUARD ^ command ^ address ^ length);
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
    }

    if (flash_read_compare(address, 0, length) != 0) {
        return ERR_VERIFY;
    }
    return ERR_OK;
}

static void uart_recv_payload(uint32_t length)
{
    volatile uint8_t *buf = data_buf();
    for (uint32_t i = 0; i < length; i++) {
        buf[i] = uart_recv_byte();
    }
}

void main(void)
{
    uart0_init(UART_ANCHOR_BAUD);
    sf_claim_sahb();
    debug_clear();
    uart_send_string("\r\nBL808-UART-FLASH-ANCHOR v1\r\n");

    for (;;) {
        struct request req = uart_recv_request();
        uint32_t status = ERR_OK;
        uint32_t result = ERR_OK;
        uint32_t counter = req.address + req.length;
        uint32_t sequence = read32(DEBUG_INFO_BASE + 0x20u) + 1u;
        uint32_t reboot_after_response = 0;

        write32(DEBUG_INFO_BASE + 0x00u, req.command);
        write32(DEBUG_INFO_BASE + 0x04u, req.address);
        write32(DEBUG_INFO_BASE + 0x08u, req.length);
        write32(DEBUG_INFO_BASE + 0x0Cu, req.header_checksum);
        write32(DEBUG_INFO_BASE + 0x10u, checksum_header(req.command, req.address, req.length));
        write32(DEBUG_INFO_BASE + 0x14u, ERR_BUSY);
        write32(DEBUG_INFO_BASE + 0x18u, 0);
        write32(DEBUG_INFO_BASE + 0x1Cu, 0);
        write32(DEBUG_INFO_BASE + 0x20u, sequence);
        dcache_flush_all();

        if (req.header_checksum != checksum_header(req.command, req.address, req.length)) {
            status = ERR_CHECKSUM;
        } else if (req.command == CMD_PING) {
            result = 1u;
        } else if (req.command == CMD_READ_ID) {
            result = flash_read_id();
        } else if (req.command == CMD_ERASE) {
            if (req.length == 0) {
                status = ERR_BAD_LENGTH;
            } else if (flash_erase_range(req.address, req.length) != 0) {
                status = ERR_TIMEOUT;
            }
        } else if (req.command == CMD_WRITE_VERIFY) {
            if (req.length == 0 || req.length > DATA_MAX) {
                status = ERR_BAD_LENGTH;
            } else {
                uint32_t payload_checksum = uart_recv_u32();
                uart_recv_payload(req.length);
                if (checksum_data(req.length) != payload_checksum) {
                    status = ERR_CHECKSUM;
                } else {
                    status = (uint32_t)flash_program_verify(req.address, req.length);
                }
            }
        } else if (req.command == CMD_REBOOT) {
            reboot_after_response = 1u;
        } else {
            status = ERR_BAD_COMMAND;
        }

        write32(DEBUG_INFO_BASE + 0x14u, status);
        write32(DEBUG_INFO_BASE + 0x18u, result);
        write32(DEBUG_INFO_BASE + 0x1Cu, counter);
        dcache_flush_all();
        uart_send_response(status, result, counter);
        if (reboot_after_response != 0u) {
            delay_cycles(100000000u);
            reboot_chip();
        }
    }
}

void _start(void) __attribute__((naked, section(".text.entry")));
void _start(void)
{
    __asm__ volatile(
        "csrci mstatus, 8\n"
        "csrw mie, zero\n"
        "li sp, %[stack]\n"
        "j main\n"
        :
        : [stack] "i" (ANCHOR_STACK)
    );
}

void uart_anchor_trap(void) __attribute__((naked, section(".text.trap")));
void uart_anchor_trap(void)
{
    __asm__ volatile(
        "li t0, %[trap]\n"
        "li t1, 0x54524150\n"
        "sw t1, 0(t0)\n"
        "csrr t1, mcause\n"
        "sw t1, 4(t0)\n"
        "csrr t1, mepc\n"
        "sw t1, 8(t0)\n"
        "csrr t1, mtval\n"
        "sw t1, 12(t0)\n"
        "1: j 1b\n"
        :
        : [trap] "i" (TRAP_INFO_BASE)
    );
}
