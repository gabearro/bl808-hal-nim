/*
 * lwIP system architecture layer for BL808 bare-metal (NO_SYS=1).
 *
 * Only sys_now() is required — returns milliseconds since boot.
 * The kernel's readTick() provides the underlying monotonic clock.
 */

#include "lwip/opt.h"
#include "lwip/sys.h"

/* Provided by kernel/clock.nim via {.exportc.} */
extern unsigned long long kernel_read_tick_ms(void);
extern void hw_validation_log_byte(unsigned char b) __attribute__((weak));

u32_t sys_now(void)
{
    return (u32_t)kernel_read_tick_ms();
}

/* Simple debug output via UART0 FIFO_WDATA register */
void lwip_debug_print(const char *msg)
{
    volatile unsigned int *uart_wdata = (volatile unsigned int *)0x2000A088UL;
    while (*msg) {
        unsigned char ch = (unsigned char)(*msg++);
        if (hw_validation_log_byte) {
            hw_validation_log_byte(ch);
        }
        *uart_wdata = (unsigned int)ch;
    }
    if (hw_validation_log_byte) {
        hw_validation_log_byte('\r');
        hw_validation_log_byte('\n');
    }
    *uart_wdata = '\r';
    *uart_wdata = '\n';
}
