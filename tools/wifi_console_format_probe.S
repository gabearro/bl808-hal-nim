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
  la t0, probe_trap
  csrw mtvec, t0
  la t0, _sbss
  la t1, _ebss
1:
  bgeu t0, t1, 2f
  sw zero, 0(t0)
  addi t0, t0, 4
  j 1b
2:
  call wifi_console_format_probe_main
  mv s0, a0
  call wifi_console_format_probe_report
  li t0, 0x100000
  beqz s0, probe_pass
  slli s0, s0, 16
  li t1, 0x3333
  or t1, t1, s0
  sw t1, 0(t0)
  j probe_wait
probe_pass:
  li t1, 0x5555
  sw t1, 0(t0)
probe_wait:
  wfi
  j probe_wait
.balign 4
probe_trap:
  li t0, 0x100000
  li t1, 0x00ff3333
  sw t1, 0(t0)
  j probe_wait
