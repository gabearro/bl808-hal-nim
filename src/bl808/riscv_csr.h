/*
 * RISC-V CSR access and core utility inline functions for BL808.
 * Included by all compilation units that need CSR/fence/WFI access.
 */
#ifndef RISCV_CSR_H
#define RISCV_CSR_H

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
  asm volatile("fence.i" ::: "memory");
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

#endif /* RISCV_CSR_H */
