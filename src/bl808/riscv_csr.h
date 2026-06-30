/*
 * RISC-V CSR access and core utility inline functions for BL808.
 * Included by all compilation units that need CSR/fence/WFI access.
 */
#ifndef RISCV_CSR_H
#define RISCV_CSR_H

#include <stdint.h>

static inline unsigned long __csr_read_mhartid(void) {
  unsigned long v; asm volatile("csrr %0, mhartid" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_mstatus(void) {
  unsigned long v; asm volatile("csrr %0, mstatus" : "=r"(v)); return v;
}
static inline void __csr_write_mstatus(unsigned long v) {
  asm volatile("csrw mstatus, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mie(void) {
  unsigned long v; asm volatile("csrr %0, mie" : "=r"(v)); return v;
}
static inline void __csr_write_mie(unsigned long v) {
  asm volatile("csrw mie, %0" :: "r"(v));
}
static inline unsigned long __csr_read_medeleg(void) {
  unsigned long v; asm volatile("csrr %0, medeleg" : "=r"(v)); return v;
}
static inline void __csr_write_medeleg(unsigned long v) {
  asm volatile("csrw medeleg, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mideleg(void) {
  unsigned long v; asm volatile("csrr %0, mideleg" : "=r"(v)); return v;
}
static inline void __csr_write_mideleg(unsigned long v) {
  asm volatile("csrw mideleg, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mcounteren(void) {
  unsigned long v; asm volatile("csrr %0, mcounteren" : "=r"(v)); return v;
}
static inline void __csr_write_mcounteren(unsigned long v) {
  asm volatile("csrw mcounteren, %0" :: "r"(v));
}
static inline unsigned long __csr_read_sstatus(void) {
  unsigned long v; asm volatile("csrr %0, sstatus" : "=r"(v)); return v;
}
static inline void __csr_write_sstatus(unsigned long v) {
  asm volatile("csrw sstatus, %0" :: "r"(v));
}
static inline unsigned long __csr_read_stvec(void) {
  unsigned long v; asm volatile("csrr %0, stvec" : "=r"(v)); return v;
}
static inline void __csr_write_stvec(unsigned long v) {
  asm volatile("csrw stvec, %0" :: "r"(v));
}
static inline unsigned long __csr_read_sie(void) {
  unsigned long v; asm volatile("csrr %0, sie" : "=r"(v)); return v;
}
static inline void __csr_write_sie(unsigned long v) {
  asm volatile("csrw sie, %0" :: "r"(v));
}
static inline unsigned long __csr_read_sip(void) {
  unsigned long v; asm volatile("csrr %0, sip" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_scause(void) {
  unsigned long v; asm volatile("csrr %0, scause" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_stval(void) {
  unsigned long v; asm volatile("csrr %0, stval" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_sepc(void) {
  unsigned long v; asm volatile("csrr %0, sepc" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_satp(void) {
  unsigned long v; asm volatile("csrr %0, satp" : "=r"(v)); return v;
}
static inline void __csr_write_satp(unsigned long v) {
  asm volatile("csrw satp, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mtvec(void) {
  unsigned long v; asm volatile("csrr %0, mtvec" : "=r"(v)); return v;
}
static inline void __csr_write_mtvec(unsigned long v) {
  asm volatile("csrw mtvec, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mepc(void) {
  unsigned long v; asm volatile("csrr %0, mepc" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_mcause(void) {
  unsigned long v; asm volatile("csrr %0, mcause" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_mtval(void) {
  unsigned long v; asm volatile("csrr %0, mtval" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_mscratch(void) {
  unsigned long v; asm volatile("csrr %0, mscratch" : "=r"(v)); return v;
}
static inline void __csr_write_mscratch(unsigned long v) {
  asm volatile("csrw mscratch, %0" :: "r"(v));
}
static inline unsigned long __csr_read_mip(void) {
  unsigned long v; asm volatile("csrr %0, mip" : "=r"(v)); return v;
}
static inline unsigned long __csr_read_time(void) {
  unsigned long v; asm volatile("csrr %0, time" : "=r"(v)); return v;
}
static inline void __do_wfi(void) {
  asm volatile("wfi");
}
static inline void __do_fence(void) {
  asm volatile("fence" ::: "memory");
}
static inline void __do_fence_io(void) {
  asm volatile("fence iorw, iorw" ::: "memory");
}
static inline void __do_fencei(void) {
  asm volatile(".long 0x0000100f" ::: "memory");
}
static inline void __do_sfence_vma(void) {
  asm volatile("sfence.vma x0, x0" ::: "memory");
}
static inline void __do_ecall(void) {
  asm volatile("ecall");
}
static inline void __do_ebreak(void) {
  asm volatile("ebreak");
}
static inline void __do_mret(void) {
  asm volatile("mret");
}
static inline void __csr_set_mstatus_mie(void) {
  asm volatile("csrsi mstatus, 0x8");
}
static inline void __csr_clear_mstatus_mie(void) {
  asm volatile("csrci mstatus, 0x8");
}

__attribute__((noreturn))
static inline void __d0_enter_supervisor(unsigned long entry, unsigned long stack) {
  asm volatile(
    "mv sp, %1\n"
    "csrw mepc, %0\n"
    "li t0, ~(3 << 11)\n"
    "csrr t1, mstatus\n"
    "and t1, t1, t0\n"
    "li t0, (1 << 11)\n"
    "or t1, t1, t0\n"
    "csrw mstatus, t1\n"
    "mret\n"
    :
    : "r"(entry), "r"(stack)
    : "t0", "t1", "memory");
  __builtin_unreachable();
}

/* T-Head cache maintenance (shared by D0 and M0) */
static inline void __dcache_flush_all(void) {
  asm volatile(".long 0x0010000b" ::: "memory");
}
static inline void __dcache_invalidate_all(void) {
  asm volatile(".long 0x0020000b" ::: "memory");
}
static inline void __icache_invalidate_all(void) {
  asm volatile(".long 0x0100000b" ::: "memory");
}

static inline unsigned long __dcache_line_size(void) {
#if __riscv_xlen == 64
  return 64UL;
#else
  return 32UL;
#endif
}

static inline void __dcache_ipa_addr(uintptr_t addr) {
  register uintptr_t a0 asm("a0") = addr;
  asm volatile(".long 0x02a5000b" :: "r"(a0) : "memory");
}

static inline void __dcache_cpa_addr(uintptr_t addr) {
  register uintptr_t a0 asm("a0") = addr;
  asm volatile(".long 0x0295000b" :: "r"(a0) : "memory");
}

static inline void __dcache_cipa_addr(uintptr_t addr) {
  register uintptr_t a0 asm("a0") = addr;
  asm volatile(".long 0x02b5000b" :: "r"(a0) : "memory");
}

static inline void __dcache_clean_range(uintptr_t addr, uintptr_t size) {
  if (size == 0) return;
  const uintptr_t line = __dcache_line_size();
  uintptr_t op_size = size + (addr % line);
  uintptr_t op_addr = addr & ~(line - 1UL);
  __do_fence();
  while (op_size > 0) {
    __dcache_cpa_addr(op_addr);
    op_addr += line;
    if (op_size > line) {
      op_size -= line;
    } else {
      op_size = 0;
    }
  }
  __do_fence();
}

static inline void __dcache_invalidate_range(uintptr_t addr, uintptr_t size) {
  if (size == 0) return;
  const uintptr_t line = __dcache_line_size();
  uintptr_t op_size = size + (addr % line);
  uintptr_t op_addr = addr;
  __do_fence();
  while (op_size > 0) {
    __dcache_ipa_addr(op_addr);
    op_addr += line;
    if (op_size > line) {
      op_size -= line;
    } else {
      op_size = 0;
    }
  }
  __do_fence();
}

static inline void __dcache_clean_invalidate_range(uintptr_t addr, uintptr_t size) {
  if (size == 0) return;
  const uintptr_t line = __dcache_line_size();
  uintptr_t op_size = size + (addr % line);
  uintptr_t op_addr = addr;
  __do_fence();
  while (op_size > 0) {
    __dcache_cipa_addr(op_addr);
    op_addr += line;
    if (op_size > line) {
      op_size -= line;
    } else {
      op_size = 0;
    }
  }
  __do_fence();
}

#endif /* RISCV_CSR_H */
