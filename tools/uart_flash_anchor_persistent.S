#ifndef UART_ANCHOR_PAYLOAD
#error "UART_ANCHOR_PAYLOAD must name the RAM anchor binary to embed"
#endif

    .section .text.entry, "ax", @progbits
    .global _start
_start:
    csrci mstatus, 8
    csrw mie, zero
    li sp, 0x2204f000

    la t0, anchor_payload_start
    la t1, anchor_payload_end
    li t2, 0x62020000

1:
    beq t0, t1, 2f
    lbu t3, 0(t0)
    sb t3, 0(t2)
    addi t0, t0, 1
    addi t2, t2, 1
    j 1b

2:
    fence
    .long 0x0100000b
    .long 0x0000100f
    li t0, 0x62020000
    jr t0

    .section .rodata.anchor, "a", @progbits
    .align 4
    .global anchor_payload_start
anchor_payload_start:
    .incbin UART_ANCHOR_PAYLOAD
    .align 4
    .global anchor_payload_end
anchor_payload_end:
