"""Exercise the actual per-descriptor A/B admission and copy on the host."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program


WIFI = Path(__file__).resolve().parents[1] / "src/bl808/wifi"
PLATFORM = r'''
const
  TxFeedbackRateMask = 0x3FFF'u32
  MAX_VIFS = 2
  VIF_TYPE_STA = 0'u8
  StaTxPolicyUpdateRateControl = 1
  SharedTxbufOff = 516'u
  SharedTxbufSize = 1604'u
type
  HostTxDescView = object
    policy: pointer
    staInfoIdx, vifIdx: uint8
    seqPassthrough: uint16
    bufferPtrs, bufferLens: array[4, uint]
  HostTxRateTemplateView = object
    policyWord, rateWord, retryRateControl0, retryRateControl1, retryRateControl2: uint32
    txPower, retryTxPowerControl0, retryTxPowerControl1, retryTxPowerControl2: uint32
  Vif = object
    vifType: uint8
  Config = object
    legacyRateMap, fixedRate: uint16
  Trial = object
    status: uint8
  Sta = object
    rcStats, txPolicy: pointer
    txPolicyUpdateFlags: array[1, uint8]
var
  ipcSharedEnv: array[9436, uint8]
  rcTrialSerial, txRateSampleTag: array[4, uint32]
  isHost = true
  station: Sta
  vif: Vif
  cfg: Config
  trial: Trial
  seen: TcpPathPacket
  original: uint32
  choices: int
proc txlHostSlot(d: ptr HostTxDescView): int = (if isHost: 0 else: -1)
proc vifChannelForIdx(idx: uint8): ptr Vif = addr vif
proc staInfoForIdx(idx: uint8): ptr Sta = addr station
proc rcRateCapabilities(stats: pointer): ptr Config = addr cfg
proc rcTrialControl(stats: pointer): ptr Trial = addr trial
proc logTcpPath(packet: TcpPathPacket; stage: TcpPathStage; detail: uint32) =
  doAssert stage == tcpTxFallbackChoice
  seen = packet
  original = detail
  inc choices
'''

CHECKS = r'''
const primary = 0x80000006'u32
const second = 0x80000004'u32
const third = 0x80000005'u32
const last = 0x80000400'u32
const ordinary = HostTxRateTemplateView(policyWord: 0xffff0704'u32, rateWord: primary,
  retryRateControl0: second, retryRateControl1: third, retryRateControl2: last,
  txPower: 0x48, retryTxPowerControl0: 0x49, retryTxPowerControl1: 0x4a,
  retryTxPowerControl2: 0x50)
var desc: HostTxDescView
var rate, stationRate: HostTxRateTemplateView
var at = (SharedTxbufOff + SharedTxbufSize * 3 + 4 + 48).int
proc setup(port: uint16) =
  choices = 0
  isHost = true
  rate = ordinary
  stationRate = ordinary
  vif.vifType = VIF_TYPE_STA
  cfg = Config(legacyRateMap: 1, fixedRate: 0xffff)
  trial.status = 0
  station = Sta(rcStats: addr cfg, txPolicy: addr stationRate)
  ipcSharedEnv = default(typeof(ipcSharedEnv))
  ipcSharedEnv[at+12] = 8
  ipcSharedEnv[at+14] = 0x45
  ipcSharedEnv[at+17] = 41
  ipcSharedEnv[at+23] = 6
  ipcSharedEnv[at+35] = 80
  ipcSharedEnv[at+36] = (port shr 8).uint8
  ipcSharedEnv[at+37] = (port and 255).uint8
  ipcSharedEnv[at+46] = 0x50
  ipcSharedEnv[at+47] = 0x18
  desc = HostTxDescView(policy: addr stationRate, seqPassthrough: 41)
  desc.bufferPtrs[0] = cast[uint](addr ipcSharedEnv[at+14])
  desc.bufferLens[0] = 41

for port in [55000'u16, 55001]:
  setup(port)
  txlConfigureTcpFallback(addr desc, addr rate, 0x2200)
  doAssert choices == 1 and seen.ports shr 16 == port.uint32
  doAssert original == second and stationRate == ordinary
  var expected = ordinary
  if tcpPathFallbackTreatment(seen):
    expected.retryRateControl0 = last
    expected.retryTxPowerControl0 = 0x50
  doAssert rate == expected
doAssert tcpPathFallbackTreatment(TcpPathPacket(ports: 55000'u32 shl 16)) !=
  tcpPathFallbackTreatment(TcpPathPacket(ports: 55001'u32 shl 16))

for kind in 0..17:
  setup(55001)
  var ack = 0x2200'u32
  case kind
  of 0: ack = 0
  of 1: vif.vifType = 1
  of 2: cfg.legacyRateMap = 0
  of 3: cfg.fixedRate = 0x1000
  of 4: trial.status = 2
  of 5: rate.policyWord = 0xffff0304'u32
  of 6: rate.retryRateControl2 = 0x80001000'u32
  of 7: rate.retryRateControl0 = last
  of 8: rate.rateWord = last
  of 9: isHost = false
  of 10: desc.bufferPtrs[0] = 1
  of 11: inc desc.bufferLens[0]
  of 12: ipcSharedEnv[at+35] = 81
  of 13: ipcSharedEnv[at+17] = 40
  of 14: ipcSharedEnv[at+20] = 0x20
  of 15: station.txPolicy = nil
  of 16: desc.staInfoIdx = 255
  else: station.txPolicyUpdateFlags[0] = 1
  let before = rate
  txlConfigureTcpFallback(addr desc, addr rate, ack)
  doAssert choices == 0 and rate == before and stationRate == ordinary
'''


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_per_frame_fallback_ab_copy(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, f'include "{WIFI / "tcp_path_trace.nim"}"\n' + PLATFORM +
                (WIFI / "fw/tx_tcp_host_packet.nim").read_text() +
                (WIFI / "fw/tx_tcp_fallback_ab.nim").read_text() + CHECKS)
