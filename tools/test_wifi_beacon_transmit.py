"""Exercise the complete beacon/TIM submission and completion state machine."""

from pathlib import Path

import pytest

from test_wifi_beacon_update import run


SETUP = r'''
proc install(vif = 0'u8; period = 3'u8) =
  reset()
  vifs[vif].beaconCountdown = 1
  vifs[vif].beaconDivisor = 1
  management.activeList.first = cast[ptr Header](addr vifs[vif])
  expectedCommit = vif.int
  let bytes = makeFrame(dtim = period)
  mm_bcn_change(request(bytes, vif))
  doAssert confirmations == @[0'u8] and allocated.len == 0
  confirmations.setLen(0)
  sentDestinations.setLen(0)
  frees = 0
proc queueTim(aid: uint16; value: uint8; vif = 0'u8) =
  let p = message(47, TASK_MM, 5, 4)
  cast[ptr MmTimUpdatePayload](p)[] = MmTimUpdatePayload(aid: aid, setFlag: value, vifIdx: vif)
  mm_tim_update(p)
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dtim_sequence_and_multicast_matrix(tmp_path: Path, mode: str) -> None:
    run(tmp_path, SETUP + r'''
for vif in 0'u8 .. 1:
  for period in [1'u8, 2, 3, 8, 255]:
    for count in 0'u8 ..< period:
      for flags in 0'u8 .. 3:
        for offset in [0'u8, 2, 248]:
          install(vif, period)
          vifs[vif].timCountdown = count
          vifs[vif].timFlags = flags
          txl_tim_ie_pool[4] = offset
          txControl.seqCounter = 65535
          stations[vif + 5].trafficFlags = 2
          let savedTemplate = cast[pointer](0x12345678'u)
          env.templatePtr = savedTemplate
          mm_bcn_transmit(vif)
          doAssert pushes == 1 and framePowerCalls == 1 and assertions == 0
          doAssert env.templatePtr == savedTemplate, "TIM writes corrupted the template pointer"
          doAssert txControl.poison == 0xDEADBEEC'u32, "TIM writes corrupted TX control"
          doAssert txControl.seqCounter == 0 and transmittedSequences == @[0'u16]
          doAssert transmittedCounts == @[count]
          let multicast = count == 0 and flags != 0
          doAssert txl_tim_ie_pool[4] == (offset or multicast.uint8)
          doAssert multicastRequests == multicast.int and postponed == multicast.int
          doAssert vifs[vif].timCountdown == (if count == 0: period - 1 else: count - 1)
          doAssert env.pendingCount == 1 and allocated.len == 0
          doAssert descriptors[vif].frameLen == vifs[vif].beaconBodyLength.uint32 + 10
          mm_bcn_transmitted(addr vifs[vif])
          doAssert env.pendingCount == 0

install(period = 3)
for tick in 0 ..< 10:
  mm_bcn_transmit(0)
  mm_bcn_transmitted(addr vifs[0])
doAssert transmittedCounts == @[0'u8, 2, 1, 0, 2, 1, 0, 2, 1, 0]
doAssert transmittedSequences == @[16'u16, 32, 48, 64, 80, 96, 112, 128, 144, 160]
''', mode, transmit=True)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_transmit_gates_and_rejected_submission(tmp_path: Path, mode: str) -> None:
    run(tmp_path, SETUP + r'''
for gate in 0 .. 7:
  install()
  case gate
  of 0: env.active = 1
  of 1: env.pendingCount = 1
  of 2: management.activeList.first = nil
  of 3: vifs[0].vifType = 0
  of 4: vifs[0].beaconEnabled = 0
  of 5: vifs[0].beaconCountdown = 0
  of 6: onChannel = false
  of 7: vifs[0].beaconTxDesc = nil
  else: discard
  let before = txl_tim_ie_pool
  let beforeCounter = txControl.seqCounter
  mm_bcn_transmit(0)
  doAssert pushes == 0 and multicastRequests == 0
  doAssert framePowerCalls == (if gate == 6: 1 else: 0)
  doAssert txl_tim_ie_pool == before and txControl.seqCounter == beforeCounter
  if gate == 0: doAssert env.transmitRequested == 1
  if gate == 1: doAssert assertions == 1 and env.pendingCount == 1

install()
vifs[0].timFlags = 3
txControl.seqCounter = 4095
pushAccept = false
let beforeTim = txl_tim_ie_pool
let beforeCount = vifs[0].timCountdown
let beforeHeader = pool.bytes[348 ..< 384]
let beforeLength = descriptors[0].frameLen
mm_bcn_transmit(0)
doAssert pushes == 1 and env.pendingCount == 0
doAssert txl_tim_ie_pool == beforeTim and vifs[0].timCountdown == beforeCount
doAssert txControl.seqCounter == 4096 and multicastRequests == 0 and postponed == 0
doAssert pool.bytes[348 ..< 384] == beforeHeader
doAssert descriptors[0].frameLen == beforeLength
pushAccept = true
mm_bcn_transmit(0)
doAssert env.pendingCount == 1 and transmittedSequences == @[16'u16]
doAssert multicastRequests == 1
let pendingTim = txl_tim_ie_pool
let pendingSequence = txControl.seqCounter
mm_bcn_transmit(0)
doAssert pushes == 2 and assertions == 1
doAssert pendingTim == txl_tim_ie_pool and pendingSequence == txControl.seqCounter
mm_bcn_transmitted(addr vifs[0])

# An unregistered AP must not be visited merely because its table slot exists.
install(1)
vifs[0].beaconEnabled = 1
vifs[0].beaconCountdown = 1
vifs[0].beaconDivisor = 1
mm_bcn_transmit(0)
doAssert pushes == 1 and descriptors[0].frameLen == 0
mm_bcn_transmitted(addr vifs[1])
''', mode, transmit=True)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_completion_reservation_and_deferred_tim_order(tmp_path: Path, mode: str) -> None:
    run(tmp_path, SETUP + r'''
install()
completeImmediately = true
mm_bcn_transmit(0)
doAssert pushes == 1 and env.pendingCount == 0 and assertions == 0

install()
mm_bcn_transmit(0)
doAssert env.pendingCount == 1
let replacement = request(makeFrame(prefix = 5), prefix = 5)
mm_bcn_change(replacement)
queueTim(25, 1)
doAssert allocated.len == 2 and vifs[0].timCount == 0
env.transmitRequested = 1
mm_bcn_transmitted(addr vifs[0])
doAssert transmittedTimCounts == @[0'u16, 1], "new DMA started before deferred TIM was applied"
doAssert pushes == 2 and vifs[0].timCount == 1
doAssert env.pendingCount == 1 and env.templatePtr == nil
doAssert env.timQueue.first == nil and allocated.len == 0
doAssert confirmations == @[0'u8]
doAssert descriptors[0].frameLen == vifs[0].beaconBodyLength.uint32 + vifs[0].timLength.uint32 + 4
queueTim(25, 0)
doAssert vifs[0].timCount == 1 and allocated.len == 1
mm_bcn_transmitted(addr vifs[0])
doAssert vifs[0].timCount == 0 and env.pendingCount == 0 and allocated.len == 0
doAssert assertions == 0
''', mode, transmit=True)
