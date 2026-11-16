#define wifi_rx_protected_probe_main wifi_bip_probe_main
#define wifi_rx_protected_probe_report wifi_bip_probe_report
#define wifi_rx_protected_trap_report wifi_bip_trap_report
#include "wifi_rx_protected_oracle.S"
#include "entry.h"

.section .text.bip_call_measured,"ax"
.globl bip_call_measured
.type bip_call_measured,@function
bip_call_measured:
  addi sp, sp, -16
  sw ra, 12(sp)
  li t0, 4096
  sub t0, sp, t0
  li t2, 0xa5a5a5a5
1:
  sw t2, 0(t0)
  addi t0, t0, 4
  bltu t0, sp, 1b
  call MFP_ENTRY
  mv t3, a0
  li t0, 4096
  sub t0, sp, t0
  li t2, 0xa5a5a5a5
  li t4, 1
  addi t5, t0, 64
2:
  lw t1, 0(t0)
  beq t1, t2, 3f
  li t4, 0
3:
  addi t0, t0, 4
  bltu t0, t5, 2b
  la t6, bip_stack_guard
  sw t4, 0(t6)
  li t0, 4096
  sub t0, sp, t0
4:
  bgeu t0, sp, 5f
  lw t1, 0(t0)
  bne t1, t2, 5f
  addi t0, t0, 4
  j 4b
5:
  sub t0, sp, t0
  la t6, bip_stack_used
  sw t0, 0(t6)
  mv a0, t3
  lw ra, 12(sp)
  addi sp, sp, 16
  ret
.size bip_call_measured, .-bip_call_measured
