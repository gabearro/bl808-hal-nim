## Two distinct hotspots for verifying the M0 peer-core sampler.

import bl808/[startup, core, d0profile, hpm, mmu]

var state {.volatile.} = 1'u32
var supervisorStack {.align: 16.}: array[4096, byte]
var rootTable {.align: 4096.}: PageTable
var counters: HpmConfig

proc profileWorkA() {.noinline, exportc.} =
  for _ in 0 ..< 200_000:
    state = state * 3 + 1

proc profileWorkB() {.noinline, exportc.} =
  for _ in 0 ..< 200_000:
    state = (state xor 0x12345678) + 3

proc workload() {.cdecl.} =
  var previous: uint32
  while true:
    profileWorkA()
    sfenceVma()
    profileWorkB()
    serviceD0Hpm(previous, counters, supervisor = true)

proc main() {.exportc, cdecl.} =
  systemInit()
  # Exercise both the caches and address translation in the validation workload.
  # Cache the DRAM workload and leave the XRAM mailbox uncached.
  const
    pteCacheable = 1'u64 shl 62
    pteBufferable = 1'u64 shl 61
    pteDevice = 1'u64 shl 63
  rootTable[0] = PteKernelPage or pteCacheable or pteBufferable
  rootTable[1] = (0x4000_0000'u64 shr 2) or PteMmioPage or pteDevice
  let tableAddress = cast[uint](addr rootTable[0])
  dcacheCleanRange(tableAddress, PageSize)

  let pteMemoryAttributes = 1'u shl 21
  let cachesAndPrediction = 0x67'u
  {.emit: ["asm volatile(\"csrs 0x7c0, %0\\n\\tcsrs 0x7c1, %1\" :: \"r\"(",
           pteMemoryAttributes, "), \"r\"(", cachesAndPrediction, ") : \"memory\");"].}
  configureD0SupervisorTraps()
  openD0SupervisorPmp()
  csrWriteSatp(satpForRoot(tableAddress))
  sfenceVma()
  counters = enableHpm(allowSupervisor = true, preferDataCache = defined(bl808D0ProfileDataCache))
  let stackTop = cast[uint](addr supervisorStack[0]) + supervisorStack.len.uint
  enterSupervisor(cast[uint](workload), stackTop)
