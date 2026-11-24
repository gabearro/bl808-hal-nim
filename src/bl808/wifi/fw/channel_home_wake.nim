const
  ChanHomeWakeAttempts = 5'u8  # Immediate admission plus four retries.
  ChanHomeWakeRetryUs = 5_000'u32

type ChanHomeWake = object
  timer: MmTimerView
  peer: MmVifIdentity
  serial, resetEpoch, channelEpoch: uint32
  home, remaining: uint8

var chanHomeWakes {.wifiCtrl.}: array[MAX_VIFS, ChanHomeWake]

when defined(bl808WifiBenchConnectedScan):
  var nimFwDbgHomeWakeQueued {.wifiCtrl, exportc: "nimfw_dbg_home_wake_queued".}: uint32

when defined(bl808WifiBenchConnectedScanAB):
  # Requests, last request MAC us, submissions, ACK, no ACK, software, raw.
  var nimFwDbgHomeWakeAb {.wifiCtrl, exportc: "nimfw_dbg_home_wake_ab".}: array[7, uint32]

  proc chanHomeWakeComplete(_: pointer; status: uint32) {.cdecl.} =
    let saved = irqSave()
    defer: irqRestore(saved)
    # No frame or VIF ownership: a retirement can outlive either lease.
    # TX event passes THD confirmStatus; software release can pass zero.
    nimFwDbgHomeWakeAb[6] = status
    if (status and (1'u32 shl 31)) == 0:
      inc nimFwDbgHomeWakeAb[5]
    elif (status and (1'u32 shl 23)) != 0:
      inc nimFwDbgHomeWakeAb[3]
    else:
      inc nimFwDbgHomeWakeAb[4]

proc chanHomeWakeTry(wake: ptr ChanHomeWake; saved: uint32) =
  let remaining = wake.remaining
  if remaining == 0: return
  # Detach the attempt before TX or timer callbacks can reenter this path.
  wake.remaining = 0
  let peer = wake.peer
  if not mmStaTimerCurrent(peer, wake.resetEpoch) or peer.station >= STA_INFO_TAB_ENTRIES.uint8:
    return
  let vif = vifChannelAt(peer.vif)
  let context = chanCtxtForIdx(wake.home)
  let env = chanEnvView()
  let ps = psEnvView()
  if vif.state == 0 or vif.vifType != VIF_TYPE_STA or vif.chanCtxt != context or
      env.currentCtxt != context or env.scheduledCtxt != nil or
      chanCtxtEpochs[wake.home] != wake.channelEpoch or
      (ps.enabled != 0 and (ps.statusFlags and 8'u32) == 0):
    return
  let serial = wake.serial
  template callback: pointer =
    when defined(bl808WifiBenchConnectedScanAB): cast[pointer](chanHomeWakeComplete)
    else: nil
  # Don't enter the allocator with an empty pool, where it would try an AC3
  # flush. A queued frame is not proof of an on-air ACK.
  if txFrameEnv().freeList.first == nil:
    inc nimFwDbgAutoNullSkipped
  elif txl_frame_send_null_frame(peer.station, callback, 0) == 0:
    when defined(bl808WifiBenchConnectedScan): inc nimFwDbgHomeWakeQueued
    when defined(bl808WifiBenchConnectedScanAB): inc nimFwDbgHomeWakeAb[2]
    return
  if remaining <= 1 or wake.serial != serial: return
  let deadline = macTimeNow() + ChanHomeWakeRetryUs
  if wake.serial != serial or not mmStaTimerCurrent(peer, wake.resetEpoch): return
  wake.remaining = remaining - 1
  mmTimerSetLocked(addr wake.timer, deadline, saved)

proc chanHomeWakeTimeout(argument: pointer) {.cdecl.} =
  let index = cast[uint](argument)
  if index >= MAX_VIFS.uint: return
  let saved = irqSave()
  defer: irqRestore(saved)
  let wake = addr chanHomeWakes[index]
  let delivery = mmTimerActiveDelivery(addr wake.timer)
  if delivery == nil or not delivery.cancelled:
    chanHomeWakeTry(wake, saved)

proc chanHomeWakeRequest(vifEntry: pointer; home: uint8) =
  if home > 2: return
  let saved = irqSave()
  defer: irqRestore(saved)
  when defined(bl808WifiBenchConnectedScanAB):
    inc nimFwDbgHomeWakeAb[0]
    nimFwDbgHomeWakeAb[1] = macTimeNow()
  let peer = mmCaptureVif(vifEntry)
  if not peer.captured: return
  let wake = addr chanHomeWakes[peer.index]
  inc wake.serial
  wake.peer = peer
  wake.resetEpoch = txResetEpoch
  wake.channelEpoch = chanCtxtEpochs[home]
  wake.home = home
  wake.remaining = ChanHomeWakeAttempts
  wake.timer.callback = cast[pointer](chanHomeWakeTimeout)
  wake.timer.env = peer.index.uint32
  chanHomeWakeTry(wake, saved)
