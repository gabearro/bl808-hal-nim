.macro RX_SAVE base, delta
  sw x0, (\delta + 0)(\base)
  sw x1, (\delta + 4)(\base)
  sw x2, (\delta + 8)(\base)
  sw x3, (\delta + 12)(\base)
  sw x4, (\delta + 16)(\base)
  sw x5, (\delta + 20)(\base)
  sw x6, (\delta + 24)(\base)
  sw x7, (\delta + 28)(\base)
  sw x8, (\delta + 32)(\base)
  sw x9, (\delta + 36)(\base)
  sw x10, (\delta + 40)(\base)
  sw x11, (\delta + 44)(\base)
  sw x12, (\delta + 48)(\base)
  sw x13, (\delta + 52)(\base)
  sw x14, (\delta + 56)(\base)
  sw x15, (\delta + 60)(\base)
  sw x16, (\delta + 64)(\base)
  sw x17, (\delta + 68)(\base)
  sw x18, (\delta + 72)(\base)
  sw x19, (\delta + 76)(\base)
  sw x20, (\delta + 80)(\base)
  sw x21, (\delta + 84)(\base)
  sw x22, (\delta + 88)(\base)
  sw x23, (\delta + 92)(\base)
  sw x24, (\delta + 96)(\base)
  sw x25, (\delta + 100)(\base)
  sw x26, (\delta + 104)(\base)
  sw x27, (\delta + 108)(\base)
  sw x28, (\delta + 112)(\base)
  sw x29, (\delta + 116)(\base)
  sw x30, (\delta + 120)(\base)
  sw x31, (\delta + 124)(\base)
.endm

.section .text.rx_supervisor_enter,"ax"
.globl rx_supervisor_enter
rx_supervisor_enter:
  addi sp, sp, -16
  sw ra, 12(sp)
  csrr t0, mtvec
  sw t0, 8(sp)
  la t0, rx_supervisor_exit_trap
  csrw mtvec, t0
  la t0, rx_descriptor_oracle_body
  csrw mepc, t0
  la ra, rx_supervisor_return
  csrr t0, mstatus
  li t1, 0x1800
  not t1, t1
  and t0, t0, t1
  li t1, 0x800
  or t0, t0, t1
  csrw mstatus, t0
  mret
rx_supervisor_return:
  ecall
  j rx_supervisor_return
.balign 4
rx_supervisor_exit_trap:
  csrr t0, mcause
  li t1, 9
  bne t0, t1, rx_unexpected_machine_trap
  lw t0, 8(sp)
  csrw mtvec, t0
  lw ra, 12(sp)
  addi sp, sp, 16
  ret
rx_unexpected_machine_trap:
  csrr a0, mcause
  csrr a1, mepc
  csrr a2, mtval
  call rx_oracle_unexpected_trap
  j rx_unexpected_machine_trap

.section .text.rx_store_trap,"ax"
.balign 4
.globl rx_store_trap
rx_store_trap:
  addi sp, sp, -144
  RX_SAVE sp, 0
  addi t0, sp, 144
  sw t0, 8(sp)
  mv a0, sp
  call rx_oracle_handle_store
  lw x1, 4(sp)
  lw x3, 12(sp)
  lw x4, 16(sp)
  lw x5, 20(sp)
  lw x6, 24(sp)
  lw x7, 28(sp)
  lw x8, 32(sp)
  lw x9, 36(sp)
  lw x10, 40(sp)
  lw x11, 44(sp)
  lw x12, 48(sp)
  lw x13, 52(sp)
  lw x14, 56(sp)
  lw x15, 60(sp)
  lw x16, 64(sp)
  lw x17, 68(sp)
  lw x18, 72(sp)
  lw x19, 76(sp)
  lw x20, 80(sp)
  lw x21, 84(sp)
  lw x22, 88(sp)
  lw x23, 92(sp)
  lw x24, 96(sp)
  lw x25, 100(sp)
  lw x26, 104(sp)
  lw x27, 108(sp)
  lw x28, 112(sp)
  lw x29, 116(sp)
  lw x30, 120(sp)
  lw x31, 124(sp)
  addi sp, sp, 144
  sret

.section .text.rx_store_context_check,"ax"
.globl rx_store_context_check
rx_store_context_check:
  addi sp, sp, -64
  sw ra, 0(sp)
  sw s0, 4(sp)
  sw s1, 8(sp)
  sw s2, 12(sp)
  sw s3, 16(sp)
  sw s4, 20(sp)
  sw s5, 24(sp)
  sw s6, 28(sp)
  sw s7, 32(sp)
  sw s8, 36(sp)
  sw s9, 40(sp)
  sw s10, 44(sp)
  sw s11, 48(sp)
  mv s0, a0
  mv a2, a1
  li ra, 0x101
  li t0, 0x24b08180
  li t1, 0x12345678
  li t2, 0x707
  li s1, 0x909
  li a0, 0x24b08180
  li a1, 0x87654321
  li a3, 0xd0d
  li a4, 0xe0e
  li a5, 0xf0f
  li a6, 0x1010
  li a7, 0x1111
  li s2, 0x1212
  li s3, 0x1313
  li s4, 0x1414
  li s5, 0x1515
  li s6, 0x1616
  li s7, 0x1717
  li s8, 0x1818
  li s9, 0x1919
  li s10, 0x1a1a
  li s11, 0x1b1b
  li t3, 0x1c1c
  li t4, 0x1d1d
  li t5, 0x1e1e
  li t6, 0x1f1f
  RX_SAVE s0, 0
  beqz a2, rx_check_full_store
  c.sw a1, 0(a0)
  j rx_check_store_done
rx_check_full_store:
  sw t1, 0(t0)
rx_check_store_done:
  RX_SAVE s0, 128
  lw ra, 0(sp)
  lw s0, 4(sp)
  lw s1, 8(sp)
  lw s2, 12(sp)
  lw s3, 16(sp)
  lw s4, 20(sp)
  lw s5, 24(sp)
  lw s6, 28(sp)
  lw s7, 32(sp)
  lw s8, 36(sp)
  lw s9, 40(sp)
  lw s10, 44(sp)
  lw s11, 48(sp)
  addi sp, sp, 64
  ret
