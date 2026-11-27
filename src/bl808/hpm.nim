## Machine-mode hardware performance counters on the E907 and C906.

type
  HpmEvent* = enum
    hpmCycles, hpmInstructions, hpmIcacheAccess, hpmIcacheMiss,
    hpmBranchMispredict, hpmBranchInstructions, hpmDcacheReadAccess,
    hpmDcacheReadMiss, hpmDcacheWriteAccess, hpmDcacheWriteMiss,
    hpmITlbMiss, hpmDTlbMiss, hpmJointTlbMiss

  HpmConfig* = object
    eventMask*: uint32
    layout: HpmLayout

  HpmLayout = enum
    hpmFull, hpmTlb, hpmDataCache

when defined(bl808d0):
  type HpmSnapshot* = array[HpmEvent, uint64]
else:
  type HpmSnapshot* = array[range[hpmCycles .. hpmDcacheWriteMiss], uint64]

template readCsr(csr: static int): uint =
  block:
    var value: uint
    {.emit: ["asm volatile(\"csrr %0, %1\" : \"=r\"(", value,
             ") : \"i\"(", csr, ") : \"memory\");"].}
    value

template writeCsr(csr: static int; value: uint) =
  {.emit: ["asm volatile(\"csrw %0, %1\" :: \"i\"(", csr,
           "), \"r\"(", value, ") : \"memory\");"].}

template commonEvents(use: untyped) =
  use(hpmIcacheAccess, 3, 0x1)
  use(hpmIcacheMiss, 4, 0x2)
  use(hpmBranchMispredict, 8, 0x6)
  use(hpmBranchInstructions, 9, 0x7)

template dataCacheEvents(use: untyped; a, b, c, d: static int) =
  use(hpmDcacheReadAccess, a, 0xC)
  use(hpmDcacheReadMiss, b, 0xD)
  use(hpmDcacheWriteAccess, c, 0xE)
  use(hpmDcacheWriteMiss, d, 0xF)

template events(use: untyped; layout: HpmLayout) =
  commonEvents(use)
  when defined(bl808d0):
    if layout != hpmDataCache:
      use(hpmITlbMiss, 5, 0x3)
      use(hpmDTlbMiss, 6, 0x4)
      use(hpmJointTlbMiss, 7, 0x5)
    if layout == hpmFull:
      dataCacheEvents(use, 14, 15, 16, 17)
    elif layout == hpmDataCache:
      dataCacheEvents(use, 5, 6, 7, 10)
  else:
    dataCacheEvents(use, 14, 15, 16, 17)

proc enableHpm*(allowSupervisor: static bool = false; preferDataCache = false): HpmConfig =
  ## Call from M-mode on the measured hart. This configures and claims the
  ## listed counters until the firmware changes their configuration again.
  ## D0 cores with eight event slots can count TLB or L1 data-cache activity.
  when defined(bl808d0):
    var fixedSlots = true
    template probeFixedSlot(name, slot, index: untyped) =
      writeCsr(0x320 + slot, index.uint)
      fixedSlots = (readCsr(0x320 + slot) == index.uint) and fixedSlots
    dataCacheEvents(probeFixedSlot, 14, 15, 16, 17)
    if not fixedSlots:
      result.layout = if preferDataCache: hpmDataCache else: hpmTlb

  var mask = (1'u shl 0) or (1'u shl 2)
  result.eventMask = 3
  template selectEvent(name, slot, index: untyped) =
    writeCsr(0x320 + slot, index.uint)
    if readCsr(0x320 + slot) == index.uint:
      mask = mask or (1'u shl slot)
      result.eventMask = result.eventMask or (1'u32 shl ord(name))
  events(selectEvent, result.layout)
  writeCsr(0x320, readCsr(0x320) and not mask)
  when allowSupervisor:
    static: doAssert defined(bl808d0)
    writeCsr(0x306, readCsr(0x306) or mask)

template readCounter(slot: static int; supervisor: static bool): uint64 =
  when supervisor:
    static: doAssert defined(bl808d0)
    readCsr(0xC00 + slot).uint64
  elif sizeof(uint) == 8:
    readCsr(0xB00 + slot).uint64
  else:
    block:
      var hi, lo: uint
      while true:
        hi = readCsr(0xB80 + slot)
        lo = readCsr(0xB00 + slot)
        if hi == readCsr(0xB80 + slot): break
      (hi.uint64 shl 32) or lo.uint64

proc readHpm*(snapshot: var HpmSnapshot; config: HpmConfig;
              supervisor: static bool = false) =
  ## Snapshot free-running counters. Subtract a previous snapshot for deltas.
  ## Only entries in config.eventMask are written.
  snapshot[hpmCycles] = readCounter(0, supervisor)
  snapshot[hpmInstructions] = readCounter(2, supervisor)
  template sample(name, slot, index: untyped) =
    if (config.eventMask and (1'u32 shl ord(name))) != 0:
      snapshot[name] = readCounter(slot, supervisor)
  events(sample, config.layout)
