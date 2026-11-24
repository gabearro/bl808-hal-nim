## Included by the M0 block provider. A lease belongs to one digest context.

type ShaLeasePhase = enum
  shaLeaseIdle, shaLeaseHeld, shaLeaseFailed, shaLeaseQuarantined

const
  ShaLeaseControl = ShaEnable or ShaLinkMode or ShaMaskIrq
  ShaLeasePollUs = 32'u32

var
  shaLeasePhase: ShaLeasePhase
  shaLeaseOwner: ptr Sha1Context
  shaLeaseSavedControl, shaLeaseSavedLink: uint32
  shaLeaseStart, shaLeaseBudget: uint32

proc acquireShaLease(owner: ptr Sha1Context; start, budget: uint32): bool =
  if owner == nil or budget == 0: return false
  let descriptor = cast[uint](addr shaDescriptor)
  let source = cast[uint](addr shaBlock[0])
  if not dmaVisible(descriptor, sizeof(shaDescriptor).uint) or
      not dmaVisible(source, sizeof(shaBlock).uint): return false
  let saved = shaLeaseIrqSave()
  defer: shaLeaseIrqRestore(saved)
  if shaLeasePhase != shaLeaseIdle or regRead(ClicMtimeBase) - start >= budget:
    return false
  let control = regRead(ShaControl)
  if (control and (ShaBusy or ShaEnable or ShaDone)) != 0: return false
  shaLeaseSavedControl = control
  shaLeaseSavedLink = regRead(ShaLinkAddress)
  shaLeaseOwner = owner
  shaLeaseStart = start
  shaLeaseBudget = budget
  shaLeasePhase = shaLeaseHeld
  shaDescriptor.control = ShaMode1 or ShaContinue or ShaSignalDone or ShaOneBlock
  shaDescriptor.source = source.uint32
  fenceIo()
  regWrite(ShaLinkAddress, descriptor.uint32)
  regWrite(ShaControl, ShaLeaseControl)
  true

proc leasedShaBlock(owner: ptr Sha1Context; state: var Sha1State;
                    data: ptr uint8): bool {.shaHot.} =
  if shaLeasePhase != shaLeaseHeld or owner != shaLeaseOwner or data == nil:
    return false
  let entered = regRead(ClicMtimeBase)
  if entered - shaLeaseStart >= shaLeaseBudget:
    shaLeasePhase = shaLeaseFailed
    return false
  loadShaBlock(shaBlock, data)
  for i, word in state: shaDescriptor.digest[i] = byteSwap(word)
  fenceIo()
  let triggered = regRead(ClicMtimeBase)
  regWrite(ShaControl, ShaLeaseControl or ShaTrigger)
  var status: uint32
  for i in 0 ..< ShaPollLimit:
    status = regRead(ShaControl)
    if (status and (ShaBusy or ShaDone)) == ShaDone:
      result = true
      break
    if (i and 15) == 15 and regRead(ClicMtimeBase) - triggered >= ShaLeasePollUs:
      break
  when defined(bl808WifiMbedTlsSha1Profile):
    let completed = regRead(ClicMtimeBase)
  if not result:
    # The engine may still have our DMA pointers. Block all further use
    # until reset, including calls from unrelated digest contexts.
    shaLeasePhase = if (status and ShaBusy) != 0: shaLeaseQuarantined
                   else: shaLeaseFailed
    return false
  fenceIo()
  let digest = cast[uint](addr shaDescriptor.digest[0])
  for i in 0 ..< state.len:
    state[i] = byteSwap(regRead(digest + 4'u * i.uint))
  regWrite(ShaControl, ShaLeaseControl or ShaClearDone)
  when defined(bl808WifiMbedTlsSha1Profile):
    let cleaned = regRead(ClicMtimeBase)
    inc shaProfile[0]
    shaProfile[1] += triggered - entered
    shaProfile[2] += completed - triggered
    shaProfile[3] += cleaned - completed
    shaProfile[4] = max(shaProfile[4], completed - triggered)

proc releaseShaLease(owner: ptr Sha1Context): bool =
  let saved = shaLeaseIrqSave()
  defer: shaLeaseIrqRestore(saved)
  if owner == nil or owner != shaLeaseOwner: return false
  shaLeaseOwner = nil
  if shaLeasePhase == shaLeaseQuarantined: return false
  if (regRead(ShaControl) and ShaBusy) != 0:
    shaLeasePhase = shaLeaseQuarantined
    return false
  fenceIo()
  regWrite(ShaControl, shaLeaseSavedControl)
  regWrite(ShaLinkAddress, shaLeaseSavedLink)
  clearShaDmaWords(cast[uint](addr shaDescriptor), sizeof(ShaLink) div 4)
  clearShaDmaWords(cast[uint](addr shaBlock[0]), shaBlock.len)
  fenceIo()
  shaLeasePhase = shaLeaseIdle
  true
