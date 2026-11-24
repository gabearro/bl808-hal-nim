"""Check the BL808 keepalive trace against actual completion handling."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
from std/volatile import volatileLoad, volatileStore
{.pragma: wifiCtrl.}
const MAX_VIFS = 2
type Vif = object
  vifIdx: uint8
  beaconTimeoutBase: uint32
var
  mm: tuple[keepAliveLimit: uint32]
  vif: Vif
  mmTrafficProbeEpochs: array[MAX_VIFS, uint32]
  nimFwDbgTrafficProbe: array[5, uint32]
  nimFwDbgPeerDisconnect: array[6, uint32]
  enabled, current = true
  onIrqSave: proc()
  clock: uint32
  loss: uint16
proc irqSave(): uint32 =
  result = enabled.uint32 * 8
  enabled = false
  if onIrqSave != nil:
    let action = onIrqSave
    onIrqSave = nil
    action()
proc irqRestore(saved: uint32) = enabled = saved == 8
proc txlFrameCallbackCurrent(): bool = current
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc mmEnvView(): ptr typeof(mm) = addr mm
proc mmPublishConnectionLoss(p: pointer; reason: uint16; epoch: ptr uint32) =
  doAssert p == (addr vif) and epoch[] == mmTrafficProbeEpochs[vif.vifIdx]
  loss = reason
'''


CHECKS = r'''
const
  Ack = 0x80800500'u32
  NoAck = 0x80010700'u32
  Flush = 0x40000000'u32
  AckWithoutDone = 0x00800000'u32
  Statuses = [Ack, 0'u32, AckWithoutDone, Flush, NoAck]

for incomingIrq in [false, true]:
  nimFwDbgTrafficProbeHistory = default(typeof(nimFwDbgTrafficProbeHistory))
  nimFwDbgTrafficProbe = default(typeof(nimFwDbgTrafficProbe))
  nimFwDbgPeerDisconnect = default(typeof(nimFwDbgPeerDisconnect))
  mmTrafficProbeEpochs = [0'u32, 0]
  vif = Vif(vifIdx: 1)
  mm.keepAliveLimit = 3
  loss = 0
  enabled = incomingIrq
  for i, status in Statuses:
    clock = 120'u32 + i.uint32
    mm_ap_traffic_probe_cfm(addr vif, status)
    doAssert enabled == incomingIrq and loss == 0
  let first = nimFwDbgTrafficProbeHistory
  doAssert first[0..2] == [10'u32, 1, 3]
  doAssert first[3..12] == [120'u32, Ack, 121, 0, 122, AckWithoutDone,
                            123, Flush, 124, NoAck]
  doAssert nimFwDbgTrafficProbe == [0'u32, 0, 1, 4, NoAck]
  doAssert vif.beaconTimeoutBase == 120 and mm.keepAliveLimit == 9
  doAssert mmTrafficProbeEpochs == [0'u32, 1]

  current = false
  mm_ap_traffic_probe_cfm(addr vif, NoAck)
  doAssert nimFwDbgTrafficProbeHistory == first
  current = true

  # A software retirement with an exhausted budget is still not link loss.
  mm.keepAliveLimit = 0
  mm_ap_traffic_probe_cfm(addr vif, Flush)
  doAssert mm.keepAliveLimit == 0 and loss == 0
  mm_ap_traffic_probe_cfm(addr vif, NoAck)
  doAssert mm.keepAliveLimit == 10 and loss == 22

  # Overwrite the ring while the MAC timestamp wraps.
  for i in 0'u32 .. 8'u32:
    clock = high(uint32) - 4'u32 + i
    mm_ap_traffic_probe_cfm(addr vif, if i mod 2 == 0: Ack else: Flush)
  let latest = nimFwDbgTrafficProbeHistory
  doAssert latest[0..2] == [32'u32, 2, 8]
  for i in 0'u32 .. 7'u32:
    doAssert latest[3 + 2*i.int] == high(uint32) - 3'u32 + i
    doAssert latest[4 + 2*i.int] == (if i mod 2 == 0: Flush else: Ack)
  doAssert mm.keepAliveLimit == 10 and enabled == incomingIrq

  nimFwDbgPeerDisconnect[0] = 0x50454552'u32
  clock = 150
  mm_ap_traffic_probe_cfm(addr vif, NoAck)
  mm_ap_traffic_probe_cfm(addr vif, Ack)
  doAssert nimFwDbgTrafficProbeHistory == latest
  doAssert nimFwDbgTrafficProbe[2] == 7 and nimFwDbgTrafficProbe[3] == 11
  doAssert vif.beaconTimeoutBase == 150 and mm.keepAliveLimit == 10
  doAssert enabled == incomingIrq

  nimFwDbgPeerDisconnect[0] = 0
  onIrqSave = proc() = current = false
  mm_ap_traffic_probe_cfm(addr vif, Flush)
  doAssert nimFwDbgTrafficProbeHistory == latest and enabled == incomingIrq
  current = true
'''


def history_source() -> str:
    power = (FW / "power_save.nim").read_text()
    history_start = power.index("when defined(bl808WifiDiagTrafficProbeHistory):")
    callback_start = power.index("proc mm_ap_traffic_probe_cfm")
    return power[history_start:callback_start]


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_traffic_probe_history(tmp_path: Path, mode: str) -> None:
    power = (FW / "power_save.nim").read_text()
    clock = r'''
proc macTimeNow(): uint32 =
  if (nimFwDbgTrafficProbeHistory[0] and 1) != 0:
    doAssert not enabled
  clock
'''
    code = PLATFORM + "proc macTimeNow(): uint32\n" + history_source() + clock
    code += procedure(power, "mm_ap_traffic_probe_cfm") + CHECKS
    run_program(tmp_path, mode, code, defines=(
        "bl808WifiDiagLinkDrop", "bl808WifiDiagTrafficProbeHistory",
    ))
