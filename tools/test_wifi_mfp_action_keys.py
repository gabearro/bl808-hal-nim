"""Check robust Action key setup without changing handshake deauthentication."""
from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_mfp_control import KEY_CONTEXT, PLATFORM, RX_CONTEXT, RX_MIC_MODEL
from test_wifi_mgt_receive import management_source
from test_wifi_tx_counter_limit import SETUP
from test_wifi_tx_security import program_source


def replace_once(code: str, old: str, new: str) -> str:
    assert code.count(old) == 1, old
    return code.replace(old, new, 1)


def tx_source() -> str:
    code = program_source()
    code = replace_once(code, "    rateTemplate: HostTxRateTemplateView\n",
                        "    rateTemplate: HostTxRateTemplateView\n    macHeader: array[512, uint8]\n")
    code = replace_once(code, "    policy, bufDesc: pointer\n",
                        "    policy, bufDesc, hwDesc, callback, callbackArg: pointer\n")
    code = replace_once(code, "    keyMat, keyHolder: pointer\n",
                        "    keyMat, keyHolder: pointer\n    macAddr: array[6, uint8]\n"
                        "    capabilityFlags: uint32\n    valid, instNbr: uint8\n")
    code = replace_once(code, "    flags: uint32\n    groupKeyPtr: pointer\n",
                        "    flags: uint32\n    groupKeyPtr: pointer\n"
                        "    vifType: uint8\n    macAddr: array[6, uint8]\n")
    code += layouts("TxSessionIdentity", "MacDataFrameHeaderView", "AddBaRspActionBodyView")
    code += r'''
const
  VIF_TYPE_AP = 2'u8
  TxlFramePayloadSize = 512'u32
type Hw = object
  payloadStart, payloadEnd, frameLen: uint32
var
  hw: Hw
  pushes, releases, allocations: int
proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)
proc hostTxDataHeader(d: ptr HostTxDescView): ptr MacDataFrameHeaderView =
  cast[ptr MacDataFrameHeaderView](addr hostTxLinkDescAt(d.bufDesc).macHeader[0])
proc addBaRspActionBodyAt(p: pointer): ptr AddBaRspActionBodyView =
  cast[ptr AddBaRspActionBodyView](p)
proc staDeleteEpoch(i: uint8): uint32 = 0
var rxVifEpochs: array[2, uint32]
var txResetEpoch: uint32
proc txlFrameLeaseToken(d: ptr HostTxDescView): uint32 = 1
proc txlFramePreparationCurrent(d: ptr HostTxDescView; identity: TxSessionIdentity;
                                token: uint32): bool = token == 1
proc tpc_update_frame_tx_power(vif, frame: pointer) = discard
proc nextTxSeqCtrl(): uint16 = 0x1230
'''
    code += SETUP
    code += r'''
proc txl_frame_get(size: uint32): pointer =
  doAssert size == 512
  inc allocations
  desc.hwDesc = addr hw
  hw = Hw(payloadStart: 0x62004000)
  addr desc
proc txl_frame_release(p: pointer; callback: bool) =
  doAssert p == addr desc
  inc releases
proc txl_frame_push(p: pointer; ac: uint8): uint8 {.discardable.} =
  doAssert p == (addr desc) and ac == 3
  inc pushes
  1
'''
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "mfp_is_robust_frame")
    code += procedure((FW / "crypto_mfp_hsu.nim").read_text(), "mfp_protect_mgmt_frame")
    code += procedure((FW / "scan_station_ap_me.nim").read_text(), "me_build_add_ba_rsp")
    return code + procedure((FW / "block_ack.nim").read_text(), "bam_send_air_action_frame")


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_pmf_addba_requires_pairwise_protection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, tx_source() + r'''
for vif in 0'u8..1:
  for station in 0'u8..6:
    for enabled in [false, true]:
      for pmf in [false, true]:
        for igtk in [false, true]:
          for keyState in 0..4:
            setup(2, 41, enabled)
            stations[station] = stations[3]
            stations[station].instNbr = vif
            stations[station].valid = 1
            stations[station].macAddr[0] = 2
            stations[station].capabilityFlags = if pmf: 8 else: 0
            key.keyIdx = 8 + station
            vifs[vif].groupKeyPtr = if igtk: cast[pointer](1) else: nil
            case keyState
            of 0: discard
            of 1: keys.pairwiseKey = nil
            of 2: key.installed = 0
            of 3: key.pnLow = high(uint32); key.pnHigh = 0xFFFF
            else: key.cipherType = 1
            pushes = 0
            releases = 0
            allocations = 0
            let before = key
            bam_send_air_action_frame(station, nil, 1, 0xEF, 0x0302, 0, nil)
            let ready = not pmf or keyState == 0
            doAssert allocations == 1 and pushes == ready.int and releases == (not ready).int,
              "PMF ADDBA response bypassed the pairwise-key protection path"
            doAssert interrupts == enabled
            if ready:
              let header = hostTxDataHeader(addr desc)
              doAssert header.frameControl == (if pmf: 0x40D0'u16 else: 0xD0'u16)
              let at = if pmf: 32 else: 24
              let body = addBaRspActionBodyAt(addr link.macHeader[at])
              doAssert body.category == 3 and body.action == 1 and body.dialogToken == 0xEF
              doAssert body.baParams == 0x0302 and body.statusCode == 0
              doAssert hw.frameLen == (if pmf: 53'u32 else: 37'u32)
              if pmf:
                doAssert key.pnLow == 42 and desc.hdrLen == 8 and desc.secTailLen == 8
                doAssert link.macHeader[24] == 42 and link.macHeader[27] == 0xA0
              else: doAssert key == before
            elif keyState != 4:
              doAssert key == before
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_early_robust_action_not_published(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, management_source() + r'''
for vif in 0'u8..1:
  for station in 0'u8..6:
    for kind in [0'u8, 2]:
      for enabled in [false, true]:
        for pmf in [false, true]:
          for category in [0'u8, 3, 4, 7, 8, 11, 15, 16, 127]:
            reset(0xD0, vif, station, kind)
            interrupts = enabled
            stations[station].capabilityFlags = if pmf: 8 else: 0
            frame.body[0] = category
            frame.body[1] = 0
            let before = frame
            let robust = category notin [4'u8, 7, 11, 15, 127]
            discard rxu_mgt_frame_check(addr desc, station)
            if pmf and robust:
              doAssert sent == 0 and allocationCalls == 0 and uploads == 0,
                "pre-key robust Action reached management publication"
              doAssert decodes == 0
            else:
              let routed = category == 3 or (category == 8 and kind == 0)
              doAssert sent == routed.int and allocationCalls == routed.int and decodes == 1
            doAssert frame == before and interrupts == enabled
''')


def rx_source() -> str:
    crypto = (FW / "crypto_mfp_hsu.nim").read_text()
    return (PLATFORM + procedure((FW / "kernel_mac_channel.nim").read_text(), "mfp_is_robust_frame")
            + KEY_CONTEXT + RX_CONTEXT + RX_MIC_MODEL + procedure(crypto, "mfpIgnoreRxMgmtFrame")
            + procedure(crypto, "mfp_ignore_mgmt_frame"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan", "firmware"])
def test_action_and_handshake_deauth_policy(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rx_source() + r'''
for vif in 0'u8..1:
  for station in 0'u8..6:
    for enabled in [false, true]:
      for pmf in [false, true]:
        for igtk in [false, true]:
          for protected in [false, true]:
            for subtype in [0xA0'u16, 0xC0, 0xD0]:
              for reason in [3'u8, 6, 7, 8]:
                var data: array[32, uint8]
                data[24] = reason
                var status = MfpMgmtFramePolicyView(frameCtrl: subtype or
                  (if protected: 0x4000'u16 else: 0), bodyOffset: 24,
                  staIdx: station, vifIdx: vif)
                vifs = default(typeof(vifs))
                vifs[vif].keys.groupKeyPtr = if igtk: 1 else: 0
                stations[station].capabilityFlags = if pmf: 8 else: 0
                interrupts = enabled
                var upload = 1'u8
                var flags = 0xA0'u8
                let before = data
                let action = subtype == 0xD0
                let robust = not action or reason != 7
                let saQuery = pmf and igtk and not protected and not action and reason in [6'u8, 7]
                let ignored = pmf and robust and ((action and not igtk) or
                  (igtk and not protected and (action or not saQuery)))
                doAssert mfp_ignore_mgmt_frame(addr status, addr data[0], 26,
                  addr upload, addr flags) == ignored, "robust Action/handshake policy"
                doAssert upload == (not ignored).uint8
                doAssert flags == (if saQuery: 0xA1'u8 else: 0xA0'u8)
                doAssert data == before and interrupts == enabled and micCalls == 0
''')
