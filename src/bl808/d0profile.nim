## Read the C906 retire monitor from a peer core. The MM domain must be powered.

import core, hpm, memmap, mmio
when defined(bl808m0):
  import irq

const
  D0RetireStatus = MmMiscBase + 0x0C'u
  D0RetirePcLow = MmMiscBase + 0x10'u
  D0PcHighMask = 0x00FF_0000'u32
  D0HpmEventCount* = ord(high(HpmEvent)) + 1
  D0HpmRequest = XramBase + 0x3B00'u
  D0HpmReply = XramBase + 0x3B40'u
  D0HpmValues = D0HpmReply + 8
  D0HpmReplySize = 8 + D0HpmEventCount * 8

proc readD0RetireSample*(status, pcLow: var uint32): bool =
  ## The status word also holds PC[39:32]. Retry if it changes at a boundary.
  for _ in 0 ..< 3:
    let before = regRead(D0RetireStatus)
    let pc = regRead(D0RetirePcLow)
    let after = regRead(D0RetireStatus)
    if ((before xor after) and D0PcHighMask) == 0:
      status = after
      pcLow = pc
      return true

when defined(bl808m0):
  proc initD0HpmObserver*() =
    ## Start a clean mailbox before releasing the workload on D0.
    regWrite(D0HpmReply, 0)
    dcacheCleanRange(D0HpmReply, 4)
    regWrite(D0HpmRequest, 0)
    dcacheCleanRange(D0HpmRequest, 4)
    fenceIo()

  proc requestD0Hpm*(values: var array[D0HpmEventCount, uint64];
                    eventMask: var uint32): bool =
    let seq = regRead(D0HpmRequest) + 1
    regWrite(D0HpmRequest, seq)
    dcacheCleanRange(D0HpmRequest, 4)
    fenceIo()
    let deadline = clicReadMtime() + 2_000_000
    while clicReadMtime() < deadline:
      dcacheInvalidateRange(D0HpmReply, D0HpmReplySize.uint)
      if regRead(D0HpmReply) == seq:
        fenceIo()
        eventMask = regRead(D0HpmReply + 4)
        for i in 0 ..< values.len:
          let address = D0HpmValues + i.uint * 8
          values[i] = regRead(address).uint64 or (regRead(address + 4).uint64 shl 32)
        return true
      delayUs(100)

when defined(bl808d0):
  proc serviceD0Hpm*(previous: var uint32; config: HpmConfig;
                     supervisor: static bool = false) =
    ## Call periodically after enableHpm(). S-mode needs uncached identity-mapped XRAM.
    when not supervisor:
      dcacheInvalidateRange(D0HpmRequest, 4)
    let seq = regRead(D0HpmRequest)
    if seq == 0 or seq == previous: return

    var snapshot {.noinit.}: HpmSnapshot
    readHpm(snapshot, config, supervisor)
    regWrite(D0HpmReply + 4, config.eventMask)
    for event in HpmEvent:
      let index = ord(event)
      let value = if (config.eventMask and (1'u32 shl index)) != 0: snapshot[event] else: 0'u64
      let address = D0HpmValues + index.uint * 8
      regWrite(address, value.uint32)
      regWrite(address + 4, (value shr 32).uint32)
    when not supervisor:
      dcacheCleanRange(D0HpmReply + 4, (D0HpmReplySize - 4).uint)
    fenceIo()
    regWrite(D0HpmReply, seq)
    when not supervisor:
      dcacheCleanRange(D0HpmReply, 4)
    fenceIo()
    previous = seq
