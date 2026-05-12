    .section .text
    .global _start
_start:
    # GPIO config: func_sel=25 | INT_MASK | SMT | IE.
    li   a1, 0x00401903
    li   a0, 0x200008DC
    sw   a1, 0(a0)

    # TDO is driven by the JTAG peripheral function; do not set GPIO OE.
    li   a1, 0x00401903
    li   a0, 0x200008E0
    sw   a1, 0(a0)

    li   a1, 0x00401903
    li   a0, 0x200008F4
    sw   a1, 0(a0)
    li   a0, 0x200008F8
    sw   a1, 0(a0)
    fence iorw, iorw

1:  j    1b
