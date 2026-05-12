/* LP HAD bring-up probe.
 *
 * Load this into the LP WRAM window, release the LP core, and it will:
 *   1. Write a fixed marker to XRAM
 *   2. Write a stage marker to XRAM
 *   3. Increment a heartbeat forever
 *
 * This avoids the current Nim bare-metal allocator bootstrap issue and keeps
 * the diagnostic path independent of the runtime/kernel.
 */

    .section .text
    .global _start

_start:
    /* ProbeStatusAddr = 0x40003F00 */
    li   a0, 0x40003F00
    li   a1, 0x48414432      /* "HAD2" */
    sw   a1, 0(a0)

    /* ProbeStageAddr = 0x40003F08 */
    li   a0, 0x40003F08
    li   a1, 0x1ACEE902
    sw   a1, 0(a0)

    /* ProbeHeartbeatAddr = 0x40003F04 */
    li   a0, 0x40003F04
    li   a1, 0

1:
    addi a1, a1, 1
    sw   a1, 0(a0)

    /* Rough delay so the heartbeat advances slowly enough to observe. */
    li   a2, 50000
2:
    addi a2, a2, -1
    bnez a2, 2b
    j    1b
