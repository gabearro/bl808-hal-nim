## LP-private CPS future atomics for an RV32E toolchain without ilp32e
## libatomic. The C implementation excludes LP interrupts; it is not a
## cross-core shared-memory primitive.

when defined(bl808lp) and (defined(bl808kernel) or
    defined(wasmLpPagerClientQemu) or defined(wasmStealClientQemu)):
  {.compile: "../../../vendor/compiler_rt_rv32e/local_atomic.c".}
