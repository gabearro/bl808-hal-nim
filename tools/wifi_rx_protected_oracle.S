.section .init,"ax"
.globl _start
_start:
  .option push
  .option norelax
  la gp, __global_pointer$
  .option pop
  la sp, _estack
  csrw mie, zero
  li t0, 8
  csrc mstatus, t0
  li t0, 0x6000
  csrs mstatus, t0
  la t0, protected_fatal_trap
  csrw mtvec, t0
  la t0, _sbss
  la t1, _ebss
1:
  bgeu t0, t1, 2f
  sw zero, 0(t0)
  addi t0, t0, 4
  j 1b
2:
  call wifi_rx_protected_probe_main
  mv s0, a0
  call wifi_rx_protected_probe_report
  li t0, 0x100000
  beqz s0, protected_pass
  slli s0, s0, 16
  li t1, 0x3333
  or t1, t1, s0
  sw t1, 0(t0)
  j protected_wait
protected_pass:
  li t1, 0x5555
  sw t1, 0(t0)
protected_wait:
  wfi
  j protected_wait
.balign 4
protected_fatal_trap:
  csrr a0, mcause
  csrr a1, mepc
  csrr a2, mtval
  call wifi_rx_protected_trap_report
  li t0, 0x100000
  li t1, 0x00ff3333
  sw t1, 0(t0)
  j protected_wait

.section .text.protected_wexti_a6,"ax"
.globl protected_wexti_a6
.type protected_wexti_a6,@function
protected_wexti_a6:
  mv a6, a0
  mv a7, a1
  .4byte 0xdf080677
  mv a0, a2
  ret
.size protected_wexti_a6, .-protected_wexti_a6

.section .text.protected_wexti_t3,"ax"
.globl protected_wexti_t3
.type protected_wexti_t3,@function
protected_wexti_t3:
  mv t3, a0
  mv t4, a1
  .4byte 0xdf0e08f7
  mv a0, a7
  ret
.size protected_wexti_t3, .-protected_wexti_t3
