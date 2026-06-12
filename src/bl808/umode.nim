## User-mode entry and exception bridge for the secure enclave (M0 / E907).
##
## The enclave runs in M-mode and drops the untrusted application into U-mode
## behind a PMP default-deny table. The application reaches enclave services
## only through `ecall`.
##
## In CLIC mode all *exceptions* enter the `mtvec` base (interrupts use `mtvt`).
## So the enclave installs a dedicated exception entry as `mtvec`: it checks the
## previous privilege (MPP) and, for traps taken from U-mode, dispatches `ecall`
## to the service bridge or routes a fault (PMP violation, illegal op) to the
## fault hook. Anything from M-mode, or any other cause, is forwarded to the
## original `__trap_handler` unchanged — so non-U-mode behaviour is preserved.
##
## Scope (v1): U-mode runs synchronously with interrupts masked, so an ecall or
## a fault are the only traps taken from U-mode.
##
## All gated behind -d:bl808enclave and -d:bl808m0; non-enclave images unchanged.

when defined(bl808m0) and defined(bl808enclave):

  type
    EcallFrame* {.exportc.} = object
      ## Saved U-mode context at an ecall (matches the asm frame layout).
      ra*, t0*, t1*, t2*, s0*, s1*: uint32
      a0*, a1*, a2*, a3*, a4*, a5*, a6*, a7*: uint32
      mepc*: uint32

  var ecallDispatch: proc (frame: ptr EcallFrame) {.nimcall.} = nil
  var faultHook: proc (cause, mepc, mtval: uint32) {.nimcall.} = nil

  proc enclaveSetEcallDispatch*(p: proc (frame: ptr EcallFrame) {.nimcall.}) =
    ecallDispatch = p

  proc enclaveSetFaultHook*(p: proc (cause, mepc, mtval: uint32) {.nimcall.}) =
    faultHook = p

  proc enclave_ecall_entry(frame: ptr EcallFrame) {.exportc, cdecl.} =
    if ecallDispatch != nil:
      ecallDispatch(frame)
    else:
      frame.a0 = 0xFFFFFFFF'u32   # no dispatcher wired: fail safe

  proc enclave_fault_entry(cause, mepc, mtval: uint32) {.exportc, cdecl.} =
    ## Report a U-mode fault, then halt (the untrusted app is not resumed).
    if faultHook != nil:
      faultHook(cause, mepc, mtval)
    while true:
      {.emit: "__asm__ volatile(\"wfi\");".}

  # Interrupt hook (only reached when the enclave runs in direct mtvec mode, used
  # for preempting the untrusted U-mode app — e.g. a machine-timer watchdog).
  var irqHook: proc (cause: uint32) {.nimcall.} = nil
  proc enclaveSetIrqHook*(p: proc (cause: uint32) {.nimcall.}) =
    irqHook = p
  proc enclave_irq_entry(cause: uint32) {.exportc, cdecl.} =
    if irqHook != nil:
      irqHook(cause)

  {.emit: """/*TYPESECTION*/
  extern void __trap_handler(void);

  /* Enclave exception entry (installed as mtvec base). Frame layout matches
     EcallFrame: ra@0 t0@4 t1@8 t2@12 s0@16 s1@20 a0@24 a1@28 a2@32 a3@36
     a4@40 a5@44 a6@48 a7@52 mepc@56. */
  __attribute__((naked, aligned(64)))
  void __enclave_exception_entry(void) {
    asm volatile(
      "csrrw sp, mscratch, sp\n"      /* sp = M handler stack, mscratch = trap sp */
      "addi sp, sp, -80\n"
      "sw t0, 4(sp)\n"
      "sw t1, 8(sp)\n"
      /* interrupt? mcause bit 31 set (negative on RV32) -> interrupt path */
      "csrr t0, mcause\n"
      "bltz t0, 7f\n"
      /* came from U-mode? mstatus.MPP (bits 12:11) == 0 */
      "csrr t0, mstatus\n"
      "srli t1, t0, 11\n"
      "andi t1, t1, 3\n"
      "bnez t1, 9f\n"                 /* MPP != U -> fall back to __trap_handler */
      /* dispatch by exception code */
      "csrr t1, mcause\n"
      "andi t1, t1, 0x1f\n"
      "li t0, 8\n"
      "beq t1, t0, 2f\n"              /* ecall-from-U */
      /* --- fault path: report cause/epc/tval, never return --- */
      "csrr a0, mcause\n"
      "csrr a1, mepc\n"
      "csrr a2, mtval\n"
      "call enclave_fault_entry\n"
      "1: wfi\n"
      "j 1b\n"
      /* --- ecall path --- */
      "2:\n"
      "sw ra, 0(sp)\n"
      "sw t2, 12(sp)\n"
      "sw s0, 16(sp)\n"
      "sw s1, 20(sp)\n"
      "sw a0, 24(sp)\n"
      "sw a1, 28(sp)\n"
      "sw a2, 32(sp)\n"
      "sw a3, 36(sp)\n"
      "sw a4, 40(sp)\n"
      "sw a5, 44(sp)\n"
      "sw a6, 48(sp)\n"
      "sw a7, 52(sp)\n"
      "csrr t0, mepc\n"
      "addi t0, t0, 4\n"             /* advance past the 4-byte ecall */
      "sw t0, 56(sp)\n"
      "csrw mepc, t0\n"
      "mv a0, sp\n"
      "call enclave_ecall_entry\n"
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
      "lw a6, 48(sp)\n"
      "lw a7, 52(sp)\n"
      "addi sp, sp, 80\n"
      "csrrw sp, mscratch, sp\n"     /* restore trap sp; mscratch = M handler stack */
      "mret\n"
      /* --- interrupt path (timer preemption): save caller-saved, run the ISR
         on the M handler stack, return to wherever we interrupted --- */
      "7:\n"
      "sw ra, 0(sp)\n"
      "sw t2, 12(sp)\n"
      "sw t3, 16(sp)\n"
      "sw t4, 20(sp)\n"
      "sw t5, 24(sp)\n"
      "sw t6, 28(sp)\n"
      "sw a0, 32(sp)\n"
      "sw a1, 36(sp)\n"
      "sw a2, 40(sp)\n"
      "sw a3, 44(sp)\n"
      "sw a4, 48(sp)\n"
      "sw a5, 52(sp)\n"
      "sw a6, 56(sp)\n"
      "sw a7, 60(sp)\n"
      "csrr a0, mcause\n"
      "call enclave_irq_entry\n"
      "lw ra, 0(sp)\n"
      "lw t0, 4(sp)\n"
      "lw t1, 8(sp)\n"
      "lw t2, 12(sp)\n"
      "lw t3, 16(sp)\n"
      "lw t4, 20(sp)\n"
      "lw t5, 24(sp)\n"
      "lw t6, 28(sp)\n"
      "lw a0, 32(sp)\n"
      "lw a1, 36(sp)\n"
      "lw a2, 40(sp)\n"
      "lw a3, 44(sp)\n"
      "lw a4, 48(sp)\n"
      "lw a5, 52(sp)\n"
      "lw a6, 56(sp)\n"
      "lw a7, 60(sp)\n"
      "addi sp, sp, 80\n"
      "csrrw sp, mscratch, sp\n"
      "mret\n"
      /* --- not from U-mode: undo and forward to the normal handler --- */
      "9:\n"
      "lw t0, 4(sp)\n"
      "lw t1, 8(sp)\n"
      "addi sp, sp, 80\n"
      "csrrw sp, mscratch, sp\n"     /* restore trap sp; mscratch = M handler stack */
      "j __trap_handler\n"
    );
  }

  /* Install the enclave entry as mtvec. CLIC mode (default) routes only
     exceptions here; direct mode also routes interrupts here (for preemption). */
  void __enclave_install_trap(unsigned long mhandler_sp) {
    asm volatile(
      "csrw mscratch, %0\n"
      "la t0, __enclave_exception_entry\n"
      "ori t0, t0, 0x3\n"            /* CLIC mode */
      "csrw mtvec, t0\n"
      :: "r"(mhandler_sp) : "t0"
    );
  }
  void __enclave_install_trap_direct(unsigned long mhandler_sp) {
    asm volatile(
      "csrw mscratch, %0\n"
      "la t0, __enclave_exception_entry\n"  /* direct mode: all traps -> here */
      "csrw mtvec, t0\n"
      :: "r"(mhandler_sp) : "t0"
    );
  }

  /* Enter U-mode: MPP=00 (U), interrupts masked, mepc=entry, user sp, mret. */
  __attribute__((noreturn))
  void __enclave_enter_umode(unsigned long entry, unsigned long user_sp) {
    asm volatile(
      "li t0, 0x00001800\n"
      "csrc mstatus, t0\n"           /* MPP = 00 -> U-mode */
      "li t0, 0x80\n"
      "csrc mstatus, t0\n"           /* MPIE = 0: keep U-mode interrupts masked */
      "csrw mepc, %0\n"
      "mv sp, %1\n"
      "mret\n"
      :: "r"(entry), "r"(user_sp) : "t0", "memory"
    );
    __builtin_unreachable();
  }

  /* Enter U-mode with interrupts ENABLED (MPIE=1), so a machine-timer interrupt
     can preempt a runaway U-mode app. The caller must have set up mie/mtimecmp. */
  __attribute__((noreturn))
  void __enclave_enter_umode_irq(unsigned long entry, unsigned long user_sp) {
    asm volatile(
      "li t0, 0x00001800\n"
      "csrc mstatus, t0\n"           /* MPP = 00 -> U-mode */
      "li t0, 0x80\n"
      "csrs mstatus, t0\n"           /* MPIE = 1: interrupts enabled in U-mode */
      "csrw mepc, %0\n"
      "mv sp, %1\n"
      "mret\n"
      :: "r"(entry), "r"(user_sp) : "t0", "memory"
    );
    __builtin_unreachable();
  }
  """.}

  proc enclaveInstallTrapVector*(handlerSp: uint) {.
    importc: "__enclave_install_trap".}
    ## Install the enclave exception entry as mtvec and load `handlerSp` into
    ## mscratch (the M-mode stack the entry swaps onto). Call before U-mode.

  proc enclaveInstallTrapVectorDirect*(handlerSp: uint) {.
    importc: "__enclave_install_trap_direct".}
    ## Like enclaveInstallTrapVector but in direct mtvec mode, so interrupts
    ## (not just exceptions) reach the enclave entry — enables U-mode preemption.

  proc enclaveEnterUmode*(entry, userSp: uint) {.
    importc: "__enclave_enter_umode", noreturn.}
    ## Drop into the U-mode application at `entry` with stack `userSp`.

  proc enclaveEnterUmodeIrq*(entry, userSp: uint) {.
    importc: "__enclave_enter_umode_irq", noreturn.}
    ## Drop into U-mode with interrupts enabled (for timer preemption).
