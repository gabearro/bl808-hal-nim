"""Check beacon channel updates across the allocator and power callouts."""

from pathlib import Path

import pytest

import test_wifi_beacon_update as beacon


REFRESH = r'''
for vif in 0'u8 .. 1:
  for irq in [false, true]:
    reset()
    vifs[vif].vifType = 0
    interruptsEnabled = irq
    var frame = newSeq[uint8](36)
    frame.add([32'u8, 1, 3])
    newBandwidth = 2
    var callbacks = 0
    allocationHook = proc(id: uint16) =
      if id != MM_CHAN_CTXT_UPDATE_REQ: return
      allocationHook = nil
      inc callbacks
      doAssert interruptsEnabled == irq
      channels[vif].prim20Freq = 2437
      vifs[vif].channelFreqPair = 2447
      contexts[vif].channel.txPower = 9
      var newerFrame = newSeq[uint8](36)
      newerFrame.add([32'u8, 1, 4])
      newBandwidth = 1
      me_beacon_check(vif, newerFrame.len.uint16, addr newerFrame[0])
    me_beacon_check(vif, frame.len.uint16, addr frame[0])
    doAssert callbacks == 1 and powerUpdates.len == 2
    doAssert channelUpdates.len == 1
    let update = channelUpdates[0]
    doAssert update.ctxtIdx == (vif + 1) and update.band == 0
    doAssert update.secChan == 1, "queued the bandwidth from before allocation"
    doAssert update.primFreq == 2437 and update.centerFreq1 == 2447
    doAssert update.centerFreq2 == 0 and update.txPower == 9
    doAssert update.ctxtIdxBandPadding == 0 and update.txPowerTailPadding == 0
    doAssert allocated.len == 0 and interruptsEnabled == irq
    doAssert vifBssStatus(addr vifs[vif]).powerConstraint == 4
'''


REBIND = r'''
for vif in 0'u8 .. 1:
  for irq in [false, true]:
    for atAllocation in [false, true]:
      reset()
      vifs[vif].vifType = 0
      interruptsEnabled = irq
      var frame = newSeq[uint8](36)
      frame.add([32'u8, 1, 3])
      newBandwidth = 2
      var callbacks, allocations: int
      let sameContext = vifs[vif].chanCtxt
      proc rebind() =
        inc callbacks
        doAssert interruptsEnabled == irq
        # An unlink/relink advances the binding even when the slot is reused.
        chanCtxtLinkEpochs[vif] += 2
        vifs[vif].chanCtxt = sameContext
        channels[vif].prim20Freq = 2462
        vifs[vif].channelFreqPair = 2452
        vifBssStatus(addr vifs[vif]).phyBandwidth = 1
      allocationHook = proc(id: uint16) =
        if id != MM_CHAN_CTXT_UPDATE_REQ: return
        inc allocations
        if atAllocation: rebind()
      if not atAllocation: powerHook = rebind
      me_beacon_check(vif, frame.len.uint16, addr frame[0])
      doAssert callbacks == 1
      doAssert allocations == atAllocation.int
      doAssert channelUpdates.len == 0, "published work from a retired binding"
      doAssert allocated.len == 0 and interruptsEnabled == irq
      doAssert vifs[vif].chanCtxt == sameContext
      doAssert channels[vif].prim20Freq == 2462
      doAssert vifBssStatus(addr vifs[vif]).phyBandwidth == 1
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", ["refresh", "rebind"])
def test_beacon_channel_handoff(tmp_path: Path, mode: str, case: str) -> None:
    beacon.run(tmp_path, {"refresh": REFRESH, "rebind": REBIND}[case], mode)
