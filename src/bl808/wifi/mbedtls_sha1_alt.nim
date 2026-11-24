## Mbed TLS SHA-1 block provider for BL808 M0. Streaming and HMAC remain
## in Mbed TLS; only the compression function is replaced.

import ../[core, memmap, mmio]
when defined(bl808AllcoreWasmHttp):
  import mbedtls_sha1_dma

type
  Sha1State = array[5, uint32]
  Sha1Block = array[16, uint32]
  Sha1Context {.importc: "mbedtls_sha1_context", header: "<mbedtls/sha1.h>".} = object
    state: Sha1State
  ShaLink = object
    control, source: uint32
    digest: array[16, uint32]
  ShaBlockResult = enum
    shaBlockFault, shaBlockDeferred, shaBlockDone

static:
  doAssert offsetof(ShaLink, digest) == 8
  doAssert sizeof(ShaLink) == 72

const
  ShaControl = SecEngBase
  ShaLinkAddress = SecEngBase + 0x50'u
  ShaBusy = 1'u32 shl 0
  ShaTrigger = 1'u32 shl 1
  ShaEnable = 1'u32 shl 5
  ShaContinue = 1'u32 shl 6
  ShaDone = 1'u32 shl 8
  ShaClearDone = 1'u32 shl 9
  ShaSignalDone = 1'u32 shl 10
  ShaMaskIrq = 1'u32 shl 11
  ShaLinkMode = 1'u32 shl 15
  ShaOneBlock = 1'u32 shl 16
  ShaMode1 = 2'u32 shl 2
  ShaPollLimit = 256
  # All-core AP profiling measures the lease only; keep the unleased path
  # uninstrumented to fit both routines in its 4 KiB RAM code bank.
  MeasureUnleasedShaBlocks = defined(bl808WifiMbedTlsSha1Profile) and
    not (defined(bl808AllcoreWasmHttp) and defined(bl808WifiMbedTlsSha1Lease))

when defined(bl808AllcoreWasmHttp):
  {.pragma: shaDma, codegenDecl: "$# $# __attribute__((section(\".wifi_sha_dma\"), aligned(16), used))".}
else:
  {.pragma: shaDma, codegenDecl: "$# $# __attribute__((section(\".wifibss.sha1\"), aligned(16), used))".}
when defined(bl808WifiHttpServer) or defined(bl808AllcoreWasmHttp):
  {.pragma: shaHot, codegenDecl: "$# __attribute__((section(\".ramfunc.sha1\"), noinline)) $#$#".}
else:
  {.pragma: shaHot.}
when defined(bl808WifiMbedTlsHotOcram):
  {.pragma: shaEntry, codegenDecl: "$# __attribute__((section(\".ramfunc.sha1.entry\"), noinline)) $#$#".}
else:
  {.pragma: shaEntry.}
var
  shaDescriptor {.shaDma.}: ShaLink
  shaBlock {.shaDma.}: Sha1Block
  # State: 0 unchecked, 1 probing, 2 usable, 3 unavailable.
  shaBackend {.exportc: "nim_mbedtls_sha1_backend".}: array[4, uint32]
when defined(bl808WifiMbedTlsSha1Profile):
  var shaProfile {.exportc: "nim_mbedtls_sha1_profile".}: array[5, uint32]
when defined(bl808AllcoreWasmHttp):
  var shaDmaInitialized: bool

proc softwareProcess(ctx: ptr Sha1Context; data: ptr uint8): cint
  {.importc: "bl808_software_sha1_process", cdecl.}

proc byteSwap(word: uint32): uint32 {.inline.} =
  (word shl 24) or ((word and 0x0000FF00'u32) shl 8) or
    ((word and 0x00FF0000'u32) shr 8) or (word shr 24)

proc dmaVisible(address, size: uint): bool {.inline.} =
  address >= WramBase and address <= WramBase + WramSize.uint - size

proc loadShaBlock(destination: var Sha1Block; data: ptr uint8) {.inline.} =
  ## Mbed TLS accepts unaligned input. Pack bytes explicitly so only the
  ## aligned WRAM destination sees word accesses.
  let source = cast[ptr UncheckedArray[uint8]](data)
  for i in 0 ..< destination.len:
    let j = 4 * i
    destination[i] = source[j].uint32 or (source[j + 1].uint32 shl 8) or
      (source[j + 2].uint32 shl 16) or (source[j + 3].uint32 shl 24)

proc clearShaDmaWords(address: uint; count: int) {.inline.} =
  for i in 0 ..< count:
    regWrite(address + 4'u * i.uint, 0)

when defined(bl808WifiMbedTlsSha1Lease):
  proc shaLeaseIrqSave(): uint32 {.inline.} =
    var previous: uint32
    {.emit: ["asm volatile(\"csrrci %0, mstatus, 8\" : \"=r\"(", previous, ") :: \"memory\");"].}
    previous

  proc shaLeaseIrqRestore(previous: uint32) {.inline.} =
    if (previous and 8) != 0:
      {.emit: "asm volatile(\"csrsi mstatus, 8\" ::: \"memory\");".}

  include mbedtls_sha1_lease

proc hardwareProcess(state: var Sha1State; data: ptr uint8): ShaBlockResult {.shaHot.} =
  when MeasureUnleasedShaBlocks:
    let enteredAt = regRead(ClicMtimeBase)
  let descriptor = cast[uint](addr shaDescriptor)
  let source = cast[uint](addr shaBlock[0])
  if not dmaVisible(descriptor, sizeof(shaDescriptor).uint) or
      not dmaVisible(source, sizeof(shaBlock).uint): return shaBlockFault
  let saved = csrReadMstatus()
  disableInterrupts()
  defer:
    if (saved and 8) != 0: enableInterrupts()
  let original = regRead(ShaControl)
  # Do not borrow a running or configured SHA engine. The bench image's
  # other cores do not own the SHA block.
  if (original and (ShaBusy or ShaEnable or ShaDone)) != 0: return shaBlockDeferred
  when defined(bl808AllcoreWasmHttp):
    if not shaDmaInitialized:
      if not wifiShaDmaWindowReady() or not wifiShaDmaContains(descriptor, sizeof(ShaLink).uint) or
          not wifiShaDmaContains(source, sizeof(Sha1Block).uint):
        return shaBlockFault
      # This NOLOAD aperture is outside the normal startup BSS ranges.
      clearShaDmaWords(descriptor, sizeof(ShaLink) div 4)
      clearShaDmaWords(source, shaBlock.len)
      fenceIo()
      shaDmaInitialized = true
  let originalLink = regRead(ShaLinkAddress)
  loadShaBlock(shaBlock, data)
  shaDescriptor.control = ShaMode1 or ShaContinue or ShaSignalDone or ShaOneBlock
  shaDescriptor.source = source.uint32
  for i, word in state: shaDescriptor.digest[i] = byteSwap(word)
  fenceIo()
  let active = ShaEnable or ShaLinkMode or ShaMaskIrq
  regWrite(ShaLinkAddress, descriptor.uint32)
  regWrite(ShaControl, active)
  when MeasureUnleasedShaBlocks:
    let triggeredAt = regRead(ClicMtimeBase)
  regWrite(ShaControl, active or ShaTrigger)
  var status: uint32
  for _ in 0 ..< ShaPollLimit:
    status = regRead(ShaControl)
    if (status and (ShaBusy or ShaDone)) == ShaDone:
      result = shaBlockDone
      break
  when MeasureUnleasedShaBlocks:
    let completedAt = regRead(ClicMtimeBase)
  if (status and ShaBusy) != 0:
    # A timed-out DMA can still refer to the private static buffers. Retire
    # the provider without recycling or rewriting either buffer.
    inc shaBackend[3]
    return shaBlockFault
  fenceIo()
  if result == shaBlockDone:
    for i in 0 ..< state.len:
      state[i] = byteSwap(regRead(descriptor + offsetof(ShaLink, digest).uint + 4'u * i.uint))
  else:
    inc shaBackend[3]
  regWrite(ShaControl, active or ShaClearDone)
  regWrite(ShaControl, original)
  regWrite(ShaLinkAddress, originalLink)
  clearShaDmaWords(descriptor, sizeof(ShaLink) div 4)
  clearShaDmaWords(source, shaBlock.len)
  when MeasureUnleasedShaBlocks:
    let cleanedAt = regRead(ClicMtimeBase)
    inc shaProfile[0]
    shaProfile[1] += triggeredAt - enteredAt
    shaProfile[2] += completedAt - triggeredAt
    shaProfile[3] += cleanedAt - completedAt
    shaProfile[4] = max(shaProfile[4], completedAt - triggeredAt)

proc probeShaBackend() =
  shaBackend[0] = 1
  var sample: array[64, uint8]
  for i in 0 ..< sample.len: sample[i] = i.uint8
  # A non-default chaining state distinguishes this from a one-shot test.
  const initial = [0x01234567'u32, 0x89abcdef'u32, 0x76543210'u32,
                   0xfedcba98'u32, 0xa5a55a5a'u32]
  var reference: Sha1Context
  reference.state = initial
  var actual = initial
  if softwareProcess(addr reference, addr sample[0]) != 0:
    shaBackend[0] = 3
    return
  case hardwareProcess(actual, addr sample[0])
  of shaBlockDeferred: shaBackend[0] = 0
  of shaBlockFault: shaBackend[0] = 3
  of shaBlockDone: shaBackend[0] = if actual == reference.state: 2'u32 else: 3'u32

when defined(bl808WifiMbedTlsSha1Lease):
  type ShaApKeyState = enum
    shaApKeyIdle, shaApKeyWaiting, shaApKeyRunning, shaApKeyFailed, shaApKeyDone

  const
    # Standalone AP bench: leave 7 ms of the 200 ms command budget for
    # dispatch, beacon setup and confirmation. The command timer is unchanged.
    ShaApKeyBudgetUs = 193_000'u32
    ShaBackendUnavailable = -0x0070.cint # MBEDTLS_ERR_PLATFORM_HW_ACCEL_FAILED

  var
    shaApKeyState: ShaApKeyState
    shaApKeyEntered: uint32

  proc beginShaApKeySetup*(): bool =
    if shaApKeyState != shaApKeyIdle: return false
    shaApKeyEntered = regRead(ClicMtimeBase)
    shaApKeyState = shaApKeyWaiting
    true

  proc finishShaApKeySetup*(): bool =
    result = shaApKeyState == shaApKeyDone
    shaApKeyState = shaApKeyIdle

  proc mbedtlsSha1LeaseBegin(ctx: ptr Sha1Context): cint
      {.exportc: "bl808_mbedtls_sha1_lease_begin", cdecl.} =
    if shaApKeyState != shaApKeyWaiting: return 0
    shaApKeyState = shaApKeyFailed
    if ctx == nil or shaLeasePhase != shaLeaseIdle: return -1
    when defined(bl808AllcoreWasmHttp):
      if not wifiShaDmaWindowReady(): return -1
    if shaBackend[0] == 0:
      # Contention is not a failed known-answer check.
      if (regRead(ShaControl) and (ShaBusy or ShaEnable or ShaDone)) != 0:
        return -1
      probeShaBackend()
    if shaBackend[0] != 2 or not acquireShaLease(ctx, shaApKeyEntered, ShaApKeyBudgetUs):
      return -1
    shaApKeyState = shaApKeyRunning
    1

  proc mbedtlsSha1LeaseEnd(ctx: ptr Sha1Context; status: cint): cint
      {.exportc: "bl808_mbedtls_sha1_lease_end", cdecl.} =
    let released = releaseShaLease(ctx)
    if status == 0 and released and
        regRead(ClicMtimeBase) - shaApKeyEntered < ShaApKeyBudgetUs:
      shaApKeyState = shaApKeyDone
      return 0
    shaApKeyState = shaApKeyFailed
    if status != 0: status else: ShaBackendUnavailable

proc mbedtlsSha1Process(ctx: ptr Sha1Context; data: ptr uint8): cint
    {.exportc: "bl808_mbedtls_sha1_process", cdecl, shaEntry.} =
  if ctx == nil or data == nil: return -0x0073
  when defined(bl808WifiMbedTlsSha1Lease):
    if shaLeasePhase != shaLeaseIdle:
      if ctx != shaLeaseOwner:
        inc shaBackend[2]
        return softwareProcess(ctx, data)
      var state {.noinit.}: Sha1State
      for i in 0 ..< state.len: state[i] = ctx.state[i]
      if not leasedShaBlock(ctx, state, data):
        if shaLeasePhase == shaLeaseQuarantined: inc shaBackend[3]
        return ShaBackendUnavailable
      for i in 0 ..< state.len: ctx.state[i] = state[i]
      inc shaBackend[1]
      return 0
  if shaBackend[0] == 0:
    probeShaBackend()
  if shaBackend[0] == 2:
    var state {.noinit.}: Sha1State
    for i in 0 ..< state.len: state[i] = ctx.state[i]
    case hardwareProcess(state, data)
    of shaBlockDone:
      for i in 0 ..< state.len: ctx.state[i] = state[i]
      inc shaBackend[1]
      return 0
    of shaBlockDeferred: discard
    of shaBlockFault: shaBackend[0] = 3
  inc shaBackend[2]
  softwareProcess(ctx, data)
