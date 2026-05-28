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
import kernel/fault
import kernel/boothealth

when defined(bl808d0):
  import memmap, mmio
when defined(bl808m0) or defined(bl808lp):
  import pds

# =============================================================================
# External symbols from linker script
# =============================================================================
{.emit: """
extern void main(void);
extern void __clic_interrupt_handler(void);
extern void __trap_handler(void);
extern void trap_vector_entry(void);
extern unsigned long _sbss;
extern unsigned long _ebss;
extern unsigned long _sdata;
extern unsigned long _edata;
extern unsigned long _sidata;
extern unsigned long _sp;
extern unsigned long __wifi_bss_start __attribute__((weak));
extern unsigned long __wifi_bss_end __attribute__((weak));
""".}

when defined(bl808m0):
  {.emit: """
  __attribute__((section(".bss.__irq_stack"), aligned(16), used))
  unsigned char __irq_stack[1024];
  """.}

# =============================================================================
# BSS initialization
# =============================================================================
{.emit: """
__attribute__((used))
void __clear_bss(void) {
  unsigned long *dst = &_sbss;
  while (dst < &_ebss) {
    *dst++ = 0;
  }
  if (&__wifi_bss_start && &__wifi_bss_end) {
    dst = &__wifi_bss_start;
    while (dst < &__wifi_bss_end) {
      *dst++ = 0;
    }
  }
}
""".}

# =============================================================================
# Data section initialization (copy from flash to RAM)
# =============================================================================
{.emit: """
__attribute__((used))
void __copy_data(void) {
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
elif defined(bl808lp):
  {.emit: """
  __attribute__((section(".rodata.__trap_vector_table"), aligned(64), used))
  void (*const __trap_vector_table[128])(void) = {
    [0 ... 127] = __clic_interrupt_handler,
    [0] = __trap_handler,
    [1] = __trap_handler,
    [2] = __trap_handler,
    [4] = __trap_handler,
    [5] = __trap_handler,
    [6] = __trap_handler,
    [8] = __trap_handler,
    [9] = __trap_handler,
    [10] = __trap_handler,
    [11] = __trap_handler,
    [12] = __trap_handler,
    [13] = __trap_handler,
    [14] = __trap_handler,
    [15] = __trap_handler
  };
  """.}

  {.emit: """
  __attribute__((naked, aligned(64)))
  void __clic_interrupt_handler(void) {
    asm volatile(
      /* LP CLIC vector IRQs use a dedicated vector entry.  Exceptions still
         enter __trap_handler and return with mret. */
      "addi sp, sp, -80\n"
      "sw ra, 0(sp)\n"
      "sw t0, 4(sp)\n"
      "sw t1, 8(sp)\n"
      "sw t2, 12(sp)\n"
      "sw s0, 16(sp)\n"
      "sw s1, 20(sp)\n"
      "sw a0, 24(sp)\n"
      "sw a1, 28(sp)\n"
      "sw a2, 32(sp)\n"
      "sw a3, 36(sp)\n"
      "sw a4, 40(sp)\n"
      "sw a5, 44(sp)\n"
      "csrr t0, mcause\n"
      "sw t0, 48(sp)\n"
      "csrr t0, mepc\n"
      "sw t0, 52(sp)\n"
      "csrr t0, mstatus\n"
      "sw t0, 56(sp)\n"
      "call trap_vector_entry\n"
      "lw t0, 56(sp)\n"
      "csrw mstatus, t0\n"
      "lw t0, 52(sp)\n"
      "csrw mepc, t0\n"
      "lw t0, 48(sp)\n"
      "csrw mcause, t0\n"
      "lw ra, 0(sp)\n"
      "lw t0, 4(sp)\n"
      "lw t1, 8(sp)\n"
      "lw t2, 12(sp)\n"
      "lw s0, 16(sp)\n"
      "lw s1, 20(sp)\n"
      "lw a0, 24(sp)\n"
      "lw a1, 28(sp)\n"
      "lw a2, 32(sp)\n"
      "lw a3, 36(sp)\n"
      "lw a4, 40(sp)\n"
      "lw a5, 44(sp)\n"
      "addi sp, sp, 80\n"
      "mret\n"
    );
  }
  """.}

  # LP E902 (RV32E) trap handler: only x0-x15 exist.
  {.emit: """
  __attribute__((naked, aligned(64)))
  void __trap_handler(void) {
    asm volatile(
      /* Save registers */
      "addi sp, sp, -80\n"
      "sw ra, 0(sp)\n"
      "sw t0, 4(sp)\n"
      "sw t1, 8(sp)\n"
      "sw t2, 12(sp)\n"
      "sw s0, 16(sp)\n"
      "sw s1, 20(sp)\n"
      "sw a0, 24(sp)\n"
      "sw a1, 28(sp)\n"
      "sw a2, 32(sp)\n"
      "sw a3, 36(sp)\n"
      "sw a4, 40(sp)\n"
      "sw a5, 44(sp)\n"
      /* Preserve CLIC trap CSRs so mret restores MPIL/MIL correctly. */
      "csrr t0, mcause\n"
      "sw t0, 48(sp)\n"
      "csrr t0, mepc\n"
      "sw t0, 52(sp)\n"
      "csrr t0, mstatus\n"
      "sw t0, 56(sp)\n"
      /* Call C handler */
      "call trap_entry\n"
      /* Restore CLIC trap CSRs before general-purpose t0 is restored. */
      "lw t0, 56(sp)\n"
      "csrw mstatus, t0\n"
      "lw t0, 52(sp)\n"
      "csrw mepc, t0\n"
      "lw t0, 48(sp)\n"
      "csrw mcause, t0\n"
      /* Restore registers */
      "lw ra, 0(sp)\n"
      "lw t0, 4(sp)\n"
      "lw t1, 8(sp)\n"
      "lw t2, 12(sp)\n"
      "lw s0, 16(sp)\n"
      "lw s1, 20(sp)\n"
      "lw a0, 24(sp)\n"
      "lw a1, 28(sp)\n"
      "lw a2, 32(sp)\n"
      "lw a3, 36(sp)\n"
      "lw a4, 40(sp)\n"
      "lw a5, 44(sp)\n"
      "addi sp, sp, 80\n"
      "mret\n"
    );
  }
  """.}
else:
  # M0 (RV32I) trap handler
  {.emit: """
  __attribute__((section(".rodata.__trap_vector_table"), aligned(64), used))
  void (*const __trap_vector_table[128])(void) = {
    [0 ... 127] = __clic_interrupt_handler,
    [0] = __trap_handler,
    [1] = __trap_handler,
    [2] = __trap_handler,
    [4] = __trap_handler,
    [5] = __trap_handler,
    [6] = __trap_handler,
    [8] = __trap_handler,
    [9] = __trap_handler,
    [10] = __trap_handler,
    [11] = __trap_handler,
    [12] = __trap_handler,
    [13] = __trap_handler,
    [14] = __trap_handler,
    [15] = __trap_handler
  };
  """.}

  {.emit: """
  __attribute__((naked, aligned(64)))
  void __clic_interrupt_handler(void) {
    asm volatile(
      /* Match the Bouffalo M0 startup: keep hardware SPUSH/SPSWAP disabled
         and save the vector IRQ frame explicitly before calling Nim. Save the
         full integer context because the BLE path enters a substantial Nim
         call graph from an asynchronous CLIC interrupt. */
      "addi sp, sp, -160\n"
      "sw ra, 0(sp)\n"
      "sw gp, 4(sp)\n"
      "sw tp, 8(sp)\n"
      "sw t0, 12(sp)\n"
      "sw t1, 16(sp)\n"
      "sw t2, 20(sp)\n"
      "sw s0, 24(sp)\n"
      "sw s1, 28(sp)\n"
      "sw a0, 32(sp)\n"
      "sw a1, 36(sp)\n"
      "sw a2, 40(sp)\n"
      "sw a3, 44(sp)\n"
      "sw a4, 48(sp)\n"
      "sw a5, 52(sp)\n"
      "sw a6, 56(sp)\n"
      "sw a7, 60(sp)\n"
      "sw s2, 64(sp)\n"
      "sw s3, 68(sp)\n"
      "sw s4, 72(sp)\n"
      "sw s5, 76(sp)\n"
      "sw s6, 80(sp)\n"
      "sw s7, 84(sp)\n"
      "sw s8, 88(sp)\n"
      "sw s9, 92(sp)\n"
      "sw s10, 96(sp)\n"
      "sw s11, 100(sp)\n"
      "sw t3, 104(sp)\n"
      "sw t4, 108(sp)\n"
      "sw t5, 112(sp)\n"
      "sw t6, 116(sp)\n"
      "csrr t0, mcause\n"
      "sw t0, 120(sp)\n"
      "csrr t0, mepc\n"
      "sw t0, 124(sp)\n"
      "csrr t0, mstatus\n"
      "sw t0, 128(sp)\n"
      "csrr t0, mscratch\n"
      "sw t0, 132(sp)\n"
      "call trap_vector_entry\n"
      "lw t0, 128(sp)\n"
      "csrw mstatus, t0\n"
      "lw t0, 124(sp)\n"
      "csrw mepc, t0\n"
      "lw t0, 120(sp)\n"
      "csrw mcause, t0\n"
      "lw t0, 132(sp)\n"
      "csrw mscratch, t0\n"
      "lw ra, 0(sp)\n"
      "lw gp, 4(sp)\n"
      "lw tp, 8(sp)\n"
      "lw t0, 12(sp)\n"
      "lw t1, 16(sp)\n"
      "lw t2, 20(sp)\n"
      "lw s0, 24(sp)\n"
      "lw s1, 28(sp)\n"
      "lw a0, 32(sp)\n"
      "lw a1, 36(sp)\n"
      "lw a2, 40(sp)\n"
      "lw a3, 44(sp)\n"
      "lw a4, 48(sp)\n"
      "lw a5, 52(sp)\n"
      "lw a6, 56(sp)\n"
      "lw a7, 60(sp)\n"
      "lw s2, 64(sp)\n"
      "lw s3, 68(sp)\n"
      "lw s4, 72(sp)\n"
      "lw s5, 76(sp)\n"
      "lw s6, 80(sp)\n"
      "lw s7, 84(sp)\n"
      "lw s8, 88(sp)\n"
      "lw s9, 92(sp)\n"
      "lw s10, 96(sp)\n"
      "lw s11, 100(sp)\n"
      "lw t3, 104(sp)\n"
      "lw t4, 108(sp)\n"
      "lw t5, 112(sp)\n"
      "lw t6, 116(sp)\n"
      "addi sp, sp, 160\n"
      "mret\n"
    );
  }
  """.}

  when defined(bl808TrapFrameDiag):
    {.emit: """
    #include <stdint.h>
    volatile uint32_t bl808_trap_frame[40];

    __attribute__((naked, aligned(64)))
	    void __trap_handler(void) {
	      asm volatile(
	        /* Capture the raw exception entry before this handler changes SP. */
	        "la t0, bl808_trap_frame\n"
	        "lw t1, 0(t0)\n"
	        "bnez t1, 0f\n"
	        "sw sp, 144(t0)\n"
	        "sw ra, 148(t0)\n"
	        "csrr t1, mcause\n"
	        "sw t1, 152(t0)\n"
	        "csrr t1, mepc\n"
	        "sw t1, 156(t0)\n"
	        "0:\n"
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
        /* Preserve CLIC trap CSRs so mret returns to the interrupted context. */
        "csrr t0, mcause\n"
        "sw t0, 64(sp)\n"
        "csrr t0, mepc\n"
        "sw t0, 68(sp)\n"
        "csrr t0, mstatus\n"
        "sw t0, 72(sp)\n"
        "csrr t0, mtval\n"
        "sw t0, 76(sp)\n"
        /* Keep the first trap frame; later halt-loop traps should not overwrite it. */
        "la t0, bl808_trap_frame\n"
        "lw t1, 0(t0)\n"
        "bnez t1, 1f\n"
        "li t1, 0x54524631\n"
        "sw t1, 0(t0)\n"
        "sw sp, 4(t0)\n"
        "lw t1, 0(sp)\n"
        "sw t1, 8(t0)\n"
        "lw t1, 4(sp)\n"
        "sw t1, 12(t0)\n"
        "lw t1, 8(sp)\n"
        "sw t1, 16(t0)\n"
        "lw t1, 12(sp)\n"
        "sw t1, 20(t0)\n"
        "lw t1, 16(sp)\n"
        "sw t1, 24(t0)\n"
        "lw t1, 20(sp)\n"
        "sw t1, 28(t0)\n"
        "lw t1, 24(sp)\n"
        "sw t1, 32(t0)\n"
        "lw t1, 28(sp)\n"
        "sw t1, 36(t0)\n"
        "lw t1, 32(sp)\n"
        "sw t1, 40(t0)\n"
        "lw t1, 36(sp)\n"
        "sw t1, 44(t0)\n"
        "lw t1, 40(sp)\n"
        "sw t1, 48(t0)\n"
        "lw t1, 44(sp)\n"
        "sw t1, 52(t0)\n"
        "lw t1, 48(sp)\n"
        "sw t1, 56(t0)\n"
        "lw t1, 52(sp)\n"
        "sw t1, 60(t0)\n"
        "lw t1, 56(sp)\n"
        "sw t1, 64(t0)\n"
        "lw t1, 60(sp)\n"
        "sw t1, 68(t0)\n"
        "lw t1, 64(sp)\n"
        "sw t1, 72(t0)\n"
        "lw t1, 68(sp)\n"
        "sw t1, 76(t0)\n"
        "lw t1, 72(sp)\n"
        "sw t1, 80(t0)\n"
        "lw t1, 76(sp)\n"
        "sw t1, 84(t0)\n"
        "sw gp, 88(t0)\n"
        "sw tp, 92(t0)\n"
        "sw s0, 96(t0)\n"
        "sw s1, 100(t0)\n"
        "sw s2, 104(t0)\n"
        "sw s3, 108(t0)\n"
        "sw s4, 112(t0)\n"
        "sw s5, 116(t0)\n"
        "sw s6, 120(t0)\n"
        "sw s7, 124(t0)\n"
        "sw s8, 128(t0)\n"
        "sw s9, 132(t0)\n"
        "sw s10, 136(t0)\n"
        "sw s11, 140(t0)\n"
        "1:\n"
        /* Call C handler */
        "call trap_entry\n"
        /* Restore CLIC trap CSRs before general-purpose t0 is restored. */
        "lw t0, 72(sp)\n"
        "csrw mstatus, t0\n"
        "lw t0, 68(sp)\n"
        "csrw mepc, t0\n"
        "lw t0, 64(sp)\n"
        "csrw mcause, t0\n"
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
  else:
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
        /* Preserve CLIC trap CSRs so mret returns to the interrupted context. */
        "csrr t0, mcause\n"
        "sw t0, 64(sp)\n"
        "csrr t0, mepc\n"
        "sw t0, 68(sp)\n"
        "csrr t0, mstatus\n"
        "sw t0, 72(sp)\n"
        /* Call C handler */
        "call trap_entry\n"
        /* Restore CLIC trap CSRs before general-purpose t0 is restored. */
        "lw t0, 72(sp)\n"
        "csrw mstatus, t0\n"
        "lw t0, 68(sp)\n"
        "csrw mepc, t0\n"
        "lw t0, 64(sp)\n"
        "csrw mcause, t0\n"
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
      /* Match Bouffalo startup: enable FP state plus T-Head ISA/MM extensions. */
      "li t0, (1 << 13)\n"
      "csrs mstatus, t0\n"
      "csrr t0, 0x7c0\n"
      "li t1, ((1 << 22) | (1 << 15))\n"
      "or t0, t0, t1\n"
      "csrw 0x7c0, t0\n"
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
elif defined(bl808m0):
  when defined(bl808directtrap):
    {.emit: """
    __attribute__((naked, section(".init")))
    void _start(void) {
      asm volatile(
        /* Disable interrupts */
        "csrci mstatus, 0x8\n"
        /* Match Bouffalo startup: enable T-Head ISA/MM extensions before C code. */
        "li t0, (1 << 13)\n"
        "csrs mstatus, t0\n"
        "csrr t0, 0x7c0\n"
        "li t1, ((1 << 22) | (1 << 15))\n"
        "or t0, t0, t1\n"
        "csrw 0x7c0, t0\n"
        /* Set stack pointer */
        "la sp, _sp\n"
        "csrw mscratch, sp\n"
        /* Direct trap mode for RAM-resident debug stubs. */
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
        /* Match Bouffalo startup: enable T-Head ISA/MM extensions before C code. */
        "li t0, (1 << 13)\n"
        "csrs mstatus, t0\n"
        "csrr t0, 0x7c0\n"
        "li t1, ((1 << 22) | (1 << 15))\n"
        "or t0, t0, t1\n"
        "csrw 0x7c0, t0\n"
        /* Set stack pointer */
        "la sp, _sp\n"
        "csrw mscratch, sp\n"
        /* Match the SDK SystemInit: disable SPUSH/SPSWAP for ipush/ipop. */
        "csrr t0, 0x7e1\n"
        "li t1, ~(0x3 << 16)\n"
        "and t0, t0, t1\n"
        "csrw 0x7e1, t0\n"
        /* Set CLIC vector bases: mtvt handles vector IRQs, mtvec handles exceptions. */
        "la t0, __trap_vector_table\n"
        "csrw 0x307, t0\n"    /* mtvt: T-Head CLIC hardware vector table */
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
else:
  {.emit: """
  __attribute__((naked, section(".init")))
  void _start(void) {
    asm volatile(
      /* Disable interrupts */
      "csrci mstatus, 0x8\n"
      /* Match Bouffalo startup: enable T-Head ISA/MM extensions before C code. */
      "csrr t0, 0x7c0\n"
      "li t1, ((1 << 22) | (1 << 15))\n"
      "or t0, t0, t1\n"
      "csrw 0x7c0, t0\n"
      /* Set stack pointer */
      "la sp, _sp\n"
      "csrw mscratch, sp\n"
      /* Set CLIC vector bases: mtvt handles vector IRQs, mtvec handles exceptions. */
      "la t0, __trap_vector_table\n"
      "csrw 0x307, t0\n"    /* mtvt: T-Head CLIC hardware vector table */
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
  faultInit()
  bootHealthInit()
  when defined(bl808m0):
    pdsConfigureLpMtimerClock()
    pdsClearIrq()
    clicInit()
  elif defined(bl808d0):
    const
      MmCpuRtc = MmMiscBase + 0x18'u
      MmCpuRtcDivMask = 0x3FF'u32
      MmCpuRtcRst = 1'u32 shl 30
      MmCpuRtcEn = 1'u32 shl 31
      D0MtimerDiv1MHz = 479'u32
        ## Ox64 D0 normally runs at 480 MHz; divider is value+1.

    regSet(MmCpuRtc, MmCpuRtcRst)
    regClear(MmCpuRtc, MmCpuRtcRst)
    regModify(MmCpuRtc, MmCpuRtcDivMask, D0MtimerDiv1MHz)
    regSet(MmCpuRtc, MmCpuRtcEn)
    plicInit()
  elif defined(bl808lp):
    pdsConfigureLpMtimerClock()
    clicInit()
