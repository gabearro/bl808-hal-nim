/* M0 helper for LP HAD bring-up diagnostics.
 *
 * Expected flow:
 *   1. OpenOCD loads the LP probe to the LP WRAM window
 *   2. OpenOCD loads this helper to 0x22030000 and resumes M0 there
 *   3. The helper performs the LP release sequence from running code
 *   4. The helper snapshots LP probe markers into M0 WRAM for later inspection
 */

    .section .text
    .global _start

    .equ HELPER_MARKER_ADDR,       0x2203FFE0
    .equ HELPER_STAGE_ADDR,        0x2203FFE4
    .equ LP_STATUS_SNAPSHOT_ADDR,  0x2203FFE8
    .equ LP_HEARTBEAT_SNAPSHOT_ADDR, 0x2203FFEC
    .equ LP_STAGE_SNAPSHOT_ADDR,   0x2203FFF0

    .equ MM_PWR_CFG,               0x2000E010
    .equ LP_BOOT_ADDR,             0x2000E144
    .equ LP_RESET_CFG,             0x20000548
    .equ LP_CLK_CFG,               0x2000E110

    .equ LP_PROBE_ENTRY,           0x22050000
    .equ LP_PROBE_STATUS,          0x40003F00
    .equ LP_PROBE_HEARTBEAT,       0x40003F04
    .equ LP_PROBE_STAGE,           0x40003F08

_start:
    li   t0, HELPER_MARKER_ADDR
    li   t1, 0x4D304C50          /* "M0LP" */
    sw   t1, 0(t0)
    li   t1, 0
    sw   t1, 4(t0)
    sw   t1, 8(t0)
    sw   t1, 12(t0)
    sw   t1, 16(t0)

    /* Power up MM domain. */
    li   t0, MM_PWR_CFG
    sw   zero, 0(t0)

    /* Program LP boot address. */
    li   t0, LP_BOOT_ADDR
    li   t1, LP_PROBE_ENTRY
    sw   t1, 0(t0)

    /* Match the known-good release sequence from jtag_switch.sh exactly. */
    li   t0, LP_RESET_CFG
    sw   zero, 0(t0)

    li   t0, LP_CLK_CFG
    li   t1, 0x10000000
    sw   t1, 0(t0)
    fence iorw, iorw

    li   t0, HELPER_STAGE_ADDR
    li   t1, 1
    sw   t1, 0(t0)

    /* Give LP time to observe the release sequence and fetch from XRAM. */
    li   t3, 500000
1:
    addi t3, t3, -1
    bnez t3, 1b

    li   t0, HELPER_STAGE_ADDR
    li   t1, 2
    sw   t1, 0(t0)

    /* Give LP time to execute the probe. */
    li   t3, 500000
2:
    addi t3, t3, -1
    bnez t3, 2b

    /* Snapshot LP-visible state into M0 WRAM. */
    li   t0, LP_PROBE_STATUS
    lw   t1, 0(t0)
    li   t2, LP_STATUS_SNAPSHOT_ADDR
    sw   t1, 0(t2)

    li   t0, LP_PROBE_HEARTBEAT
    lw   t1, 0(t0)
    li   t2, LP_HEARTBEAT_SNAPSHOT_ADDR
    sw   t1, 0(t2)

    li   t0, LP_PROBE_STAGE
    lw   t1, 0(t0)
    li   t2, LP_STAGE_SNAPSHOT_ADDR
    sw   t1, 0(t2)

    li   t0, HELPER_STAGE_ADDR
    li   t1, 3
    sw   t1, 0(t0)

3:
    j    3b
