/* M0 helper: drive GPIO6/GPIO7 as plain GPIO outputs and toggle them forever.
 *
 * This is a software-only wiring test for the BL808 <-> FTDI JTAG header.
 * GPIO6 and GPIO7 toggle in opposite phases so the host-side FTDI sampler can
 * confirm whether ADBUS3/GPIO6 and ADBUS2/GPIO7 are both electrically alive.
 */

    .section .text
    .global _start

    .equ GPIO6_CFG_ADDR,      0x200008DC
    .equ GPIO7_CFG_ADDR,      0x200008E0
    .equ GPIO_CFG_GPIO_OUT,   0x00000B46  /* func=GPIO, OE=1, SMT=1, drive=1 */
    .equ GPIO_SET_BIT,        0x02000000
    .equ GPIO_CLR_BIT,        0x04000000

_start:
    /* Delay before stealing the JTAG pins so OpenOCD can resume and exit. */
    li   t5, 20000000
0:
    addi t5, t5, -1
    bnez t5, 0b

    li   t6, GPIO6_CFG_ADDR
    li   t0, GPIO7_CFG_ADDR
    li   t1, GPIO_CFG_GPIO_OUT
    sw   t1, 0(t6)
    sw   t1, 0(t0)

1:
    /* Phase A: GPIO6=1, GPIO7=0 */
    lw   t1, 0(t6)
    li   t2, GPIO_SET_BIT
    or   t1, t1, t2
    sw   t1, 0(t6)

    lw   t1, 0(t0)
    li   t2, GPIO_CLR_BIT
    or   t1, t1, t2
    sw   t1, 0(t0)

    li   t3, 150000
2:
    addi t3, t3, -1
    bnez t3, 2b

    /* Phase B: GPIO6=0, GPIO7=1 */
    lw   t1, 0(t6)
    li   t2, GPIO_CLR_BIT
    or   t1, t1, t2
    sw   t1, 0(t6)

    lw   t1, 0(t0)
    li   t2, GPIO_SET_BIT
    or   t1, t1, t2
    sw   t1, 0(t0)

    li   t3, 150000
3:
    addi t3, t3, -1
    bnez t3, 3b

    j    1b
