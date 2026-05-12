## D0 CPS kernel Phase 5 test — scheduler + sleep on the C906 (RV64) core.
##
## Build: nim c -d:bl808d0 -d:bl808kernel examples/d0_kernel_test.nim
## Run:   qemu-system-riscv64 -M bl808 -nographic \
##          -serial mon:stdio -serial file:/tmp/d0.txt \
##          -device loader,file=examples/d0_kernel_test,cpu-num=1 \
##          -kernel examples/m0_sched_test

import bl808/startup
import bl808/mmio, bl808/memmap, bl808/core
import bl808/irq
import bl808/kernel/cps

const
  D0StatusAddr = XramBase + 0x3F80'u
  D0StatusScheduler = 1'u32 shl 0
  D0StatusTaskA = 1'u32 shl 1
  D0StatusTaskB = 1'u32 shl 2

proc setStatus(mask: uint32) =
  regSet(D0StatusAddr, mask)
  dcacheFlushAll()
  fenceIo()

proc d0TaskA(): CpsVoidFuture {.cps.} =
  var count = 0
  while count < 5:
    await sleepMs(300)
    count += 1
  setStatus(D0StatusTaskA)

proc d0TaskB(): CpsVoidFuture {.cps.} =
  var count = 0
  while count < 3:
    await sleepMs(700)
    count += 1
  setStatus(D0StatusTaskB)

proc main() {.exportc, cdecl.} =
  systemInit()

  heapInit()
  schedulerInit()

  setStatus(D0StatusScheduler)

  discard d0TaskA()
  discard d0TaskB()

  runScheduler()
