## BL808 startup / boot code.
##
## Provides the reset vector, BSS initialization, stack setup, and
## trap vector table for each core. This module must be imported by
## every firmware image.
##
## The entry point is `_start` which:
##   1. Sets up the stack pointer
##   2. Clears BSS
##   3. Sets up the trap vector
##   4. Calls `main()`

import core, irq

# =============================================================================
# External symbols from linker script
# =============================================================================
{.emit: """
extern void main(void);
extern unsigned long _sbss;
extern unsigned long _ebss;
extern unsigned long _sdata;
extern unsigned long _edata;
extern unsigned long _sidata;
extern unsigned long _sp;
""".}

# =============================================================================
# BSS initialization
# =============================================================================
{.emit: """
static void __clear_bss(void) {
  unsigned long *dst = &_sbss;
  while (dst < &_ebss) {
    *dst++ = 0;
  }
}
""".}

# =============================================================================
# Data section initialization (copy from flash to RAM)
# =============================================================================
{.emit: """
static void __copy_data(void) {
  unsigned long *src = &_sidata;
  unsigned long *dst = &_sdata;
  while (dst < &_edata) {
    *dst++ = *src++;
  }
}
""".}

# =============================================================================
# Trap handler (naked function, saves/restores context)
# =============================================================================
when defined(bl808d0):
  # D0 (RV64) trap handler
  {.emit: """
  __attribute__((naked, aligned(4)))
  void __trap_handler(void) {
    asm volatile(
      /* Save registers */
      "addi sp, sp, -256\n"
      "sd ra, 0(sp)\n"
      "sd t0, 8(sp)\n"
      "sd t1, 16(sp)\n"
      "sd t2, 24(sp)\n"
      "sd a0, 32(sp)\n"
      "sd a1, 40(sp)\n"
      "sd a2, 48(sp)\n"
      "sd a3, 56(sp)\n"
      "sd a4, 64(sp)\n"
      "sd a5, 72(sp)\n"
      "sd a6, 80(sp)\n"
      "sd a7, 88(sp)\n"
      "sd t3, 96(sp)\n"
      "sd t4, 104(sp)\n"
      "sd t5, 112(sp)\n"
      "sd t6, 120(sp)\n"
      /* Call C handler */
      "call trap_entry\n"
      /* Restore registers */
      "ld ra, 0(sp)\n"
      "ld t0, 8(sp)\n"
      "ld t1, 16(sp)\n"
      "ld t2, 24(sp)\n"
      "ld a0, 32(sp)\n"
      "ld a1, 40(sp)\n"
      "ld a2, 48(sp)\n"
      "ld a3, 56(sp)\n"
      "ld a4, 64(sp)\n"
      "ld a5, 72(sp)\n"
      "ld a6, 80(sp)\n"
      "ld a7, 88(sp)\n"
      "ld t3, 96(sp)\n"
      "ld t4, 104(sp)\n"
      "ld t5, 112(sp)\n"
      "ld t6, 120(sp)\n"
      "addi sp, sp, 256\n"
      "mret\n"
    );
  }
  """.}
else:
  # M0/LP (RV32) trap handler
  {.emit: """
  __attribute__((naked, aligned(64)))
  void __trap_handler(void) {
    asm volatile(
      /* Save registers */
      "addi sp, sp, -128\n"
      "sw ra, 0(sp)\n"
      "sw t0, 4(sp)\n"
      "sw t1, 8(sp)\n"
      "sw t2, 12(sp)\n"
      "sw a0, 16(sp)\n"
      "sw a1, 20(sp)\n"
      "sw a2, 24(sp)\n"
      "sw a3, 28(sp)\n"
      "sw a4, 32(sp)\n"
      "sw a5, 36(sp)\n"
      "sw a6, 40(sp)\n"
      "sw a7, 44(sp)\n"
      "sw t3, 48(sp)\n"
      "sw t4, 52(sp)\n"
      "sw t5, 56(sp)\n"
      "sw t6, 60(sp)\n"
      /* Call C handler */
      "call trap_entry\n"
      /* Restore registers */
      "lw ra, 0(sp)\n"
      "lw t0, 4(sp)\n"
      "lw t1, 8(sp)\n"
      "lw t2, 12(sp)\n"
      "lw a0, 16(sp)\n"
      "lw a1, 20(sp)\n"
      "lw a2, 24(sp)\n"
      "lw a3, 28(sp)\n"
      "lw a4, 32(sp)\n"
      "lw a5, 36(sp)\n"
      "lw a6, 40(sp)\n"
      "lw a7, 44(sp)\n"
      "lw t3, 48(sp)\n"
      "lw t4, 52(sp)\n"
      "lw t5, 56(sp)\n"
      "lw t6, 60(sp)\n"
      "addi sp, sp, 128\n"
      "mret\n"
    );
  }
  """.}

# =============================================================================
# Reset vector / entry point
# =============================================================================
when defined(bl808d0):
  {.emit: """
  __attribute__((naked, section(".init")))
  void _start(void) {
    asm volatile(
      /* Disable interrupts */
      "csrci mstatus, 0x8\n"
      /* Set stack pointer */
      "la sp, _sp\n"
      /* Set trap vector (direct mode) */
      "la t0, __trap_handler\n"
      "csrw mtvec, t0\n"
      /* Clear BSS */
      "call __clear_bss\n"
      /* Copy initialized data */
      "call __copy_data\n"
      /* Jump to main */
      "call main\n"
      /* If main returns, loop forever */
      "1: wfi\n"
      "j 1b\n"
    );
  }
  """.}
else:
  {.emit: """
  __attribute__((naked, section(".init")))
  void _start(void) {
    asm volatile(
      /* Disable interrupts */
      "csrci mstatus, 0x8\n"
      /* Set stack pointer */
      "la sp, _sp\n"
      /* Set trap vector (direct mode for CLIC) */
      "la t0, __trap_handler\n"
      "ori t0, t0, 0x3\n"  /* CLIC mode: mtvec[1:0] = 0b11 */
      "csrw mtvec, t0\n"
      /* Clear BSS */
      "call __clear_bss\n"
      /* Copy initialized data */
      "call __copy_data\n"
      /* Jump to main */
      "call main\n"
      /* If main returns, loop forever */
      "1: wfi\n"
      "j 1b\n"
    );
  }
  """.}

# =============================================================================
# System initialization (called from main before user code)
# =============================================================================
proc systemInit*() =
  ## Initialize core system peripherals. Call this at the start of main().
  when defined(bl808m0):
    clicInit()
  elif defined(bl808d0):
    plicInit()
  elif defined(bl808lp):
    clicInit()
