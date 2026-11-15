"""Execute the production Block Ack responder and action-frame builder."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, procedure


ROOT = FW.parents[3]

PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  VIF_TYPE_AP = 2'u8
  TASK_BAM = 6'u8
  BamIdleState = 0'u16
  TxlFramePayloadSize = 512'u32
type
  MacHeader {.packed.} = object
    frameControl, duration: uint16
    addr1, addr2, addr3: array[6, uint8]
    seqCtrl: uint16
  Link = object
    before: array[16, uint8]
    macHeader: array[512, uint8]
    after: array[16, uint8]
  HostTxDescView = object
    bufDesc, hwDesc, callback, callbackArg: pointer
    staInfoIdx, vifIdx, hdrLen, secTailLen: uint8
  Hw = object
    payloadStart, payloadEnd, frameLen: uint32
  Sta {.packed.} = object
    macAddr: array[6, uint8]
    instNbr, valid: uint8
    padding: array[78, uint8]
    wrongMode: uint8
  Vif = object
    vifType, vifIdx: uint8
    macAddr: array[6, uint8]
  MsgHeader = object
    paramLen: uint32
  Message = object
    header: MsgHeader
    payload: array[96, uint8]
var
  stas: array[7, Sta]
  vifs: array[2, Vif]
  link: Link
  desc: HostTxDescView
  hw: Hw
  mmio: uint32
  sequence: uint16
  allocations, pushes, powerUpdates, assertions: int
  allocationFails: bool
  mfp: uint32
  bam_env: array[96, uint8]
  stateCalls: int
  interrupts = true
  rxVifEpochs: array[2, uint32]
  txResetEpoch: uint32
  stationEpochs: array[7, uint32]
  resetting, retiring: bool
let MACHW_DOZE_CNTRL2_REG = cast[uint](addr mmio)

proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc staDeleteEpoch(i: uint8): uint32 =
  if i < 7: stationEpochs[i] else: 0
proc txlResetting(): bool = resetting
proc txlVifIsRetiring(i: uint8): bool = retiring
proc txlFrameLeaseToken(desc: ptr HostTxDescView): uint32 = 0
# Epoch/lease behavior is exercised with the real helpers in the control-frame suite.
proc txlFramePreparationCurrent(desc: ptr HostTxDescView; identity: TxSessionIdentity;
                                generation: uint32): bool = true
proc txl_frame_release(frame: pointer; callback: bool) =
  doAssert false, "valid Block Ack geometry should not require release"
proc staInfoForIdx(i: uint8): ptr Sta = addr stas[i]
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc hostTxHwDescAt(p: pointer): ptr Hw = cast[ptr Hw](p)
proc hostTxLinkDescAt(p: pointer): ptr Link = cast[ptr Link](p)
proc hostTxDataHeader(d: ptr HostTxDescView): ptr MacHeader =
  cast[ptr MacHeader](addr hostTxLinkDescAt(d.bufDesc).macHeader[0])
proc rxuMgtDispatchView(p: pointer): ptr RxuMgtDispatchView = cast[ptr RxuMgtDispatchView](p)
proc rxuMgtIndMsgAt(p: pointer): ptr RxuMgtIndMsgView = cast[ptr RxuMgtIndMsgView](p)
proc keMsgHdrFromPayload(p: pointer): ptr MsgHeader =
  cast[ptr MsgHeader](cast[uint](p) - sizeof(MsgHeader).uint)
proc addBaRspActionBodyAt(p: pointer): ptr AddBaRspActionBodyView =
  cast[ptr AddBaRspActionBodyView](p)
proc addBaReqActionBodyAt(p: pointer): ptr AddBaReqActionBodyView =
  cast[ptr AddBaReqActionBodyView](p)
proc meAddBaReqParamView(p: pointer): ptr MeAddBaReqParamView =
  cast[ptr MeAddBaReqParamView](p)
proc bamEnvView(): ptr BamEnvView = cast[ptr BamEnvView](addr bam_env[0])
proc ke_state_set(task: uint8; state: uint16) =
  doAssert task == TASK_BAM and state == BamIdleState
  doAssert bam_env[12] == 255
  inc stateCalls
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc blOpsFunc(index: int): pointer = nil
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_DOZE_CNTRL2_REG
  mmio
proc regWrite(address: uint; value: uint32) =
  doAssert address == MACHW_DOZE_CNTRL2_REG
  mmio = value
proc nextTxSeqCtrl(): uint16 =
  sequence = (sequence + 1) and 0xFFF
  sequence shl 4
proc txl_frame_get(size: uint32): pointer =
  doAssert size == 512
  inc allocations
  if allocationFails: return nil
  desc = HostTxDescView(bufDesc: addr link, hwDesc: addr hw)
  hw = Hw(payloadStart: 0x62004000)
  addr desc
proc tpc_update_frame_tx_power(vif, frame: pointer) =
  doAssert frame == addr desc
  inc powerUpdates
proc txl_frame_push(p: pointer; ac: uint8): uint8 {.discardable.} =
  doAssert p == (addr desc) and ac == 3
  inc pushes
  1
proc mfp_protect_mgmt_frame(p: pointer; fc, category: uint32): uint32 =
  doAssert p == (addr desc) and fc == 0xD0 and category == 3
  mfp
proc txu_cntrl_protect_mgmt_frame(p, header: pointer; size: uint32) =
  doAssert p == (addr desc) and size == 24
  let h = cast[ptr MacHeader](header)
  h.frameControl = h.frameControl or 0x4000'u16
  desc.hdrLen = 8
  desc.secTailLen = 8
  for i in 24 ..< 32: link.macHeader[i] = 0xCC
proc assert_err(file, condition: cstring; line: int) = inc assertions
proc callback(p: pointer; status: uint32) {.cdecl.} = discard

proc reset() =
  stas = default(typeof(stas))
  vifs = default(typeof(vifs))
  desc = default(HostTxDescView)
  hw = default(Hw)
  for b in link.before.mitems: b = 0xA5
  for b in link.macHeader.mitems: b = 0xA5
  for b in link.after.mitems: b = 0xA5
  for i in 0 ..< stas.len:
    stas[i].valid = 1
    stas[i].instNbr = (i mod 2).uint8
    stas[i].macAddr = [0x02'u8, 1, 2, 3, 4, i.uint8]
  for i in 0 ..< vifs.len:
    vifs[i].vifIdx = i.uint8
    vifs[i].macAddr = [0x02'u8, 9, 8, 7, 6, i.uint8]
  allocations = 0
  pushes = 0
  powerUpdates = 0
  assertions = 0
  sequence = 4095
  mmio = 0xABCD0010'u32
  allocationFails = false
  mfp = 0
  stateCalls = 0
  stationEpochs = default(typeof(stationEpochs))
  rxVifEpochs = default(typeof(rxVifEpochs))
  txResetEpoch = 0
  resetting = false
  retiring = false

proc request(message: var Message; station: uint8; params: uint16): pointer =
  message = default(Message)
  message.header.paramLen = 68
  result = addr message.payload[0]
  let fixed = rxuMgtIndMsgAt(result)
  fixed.frameLen = 9
  let view = rxuMgtDispatchView(result)
  view.staIdx = station
  view.vifIdx = stas[station].instNbr
  view.frameCtrl = 0xD0
  view.category = 3
  view.actionCode = 0
  view.dialogToken = 0xEF
  view.baParam = params
"""

CHECKS = {
    "transmit": r"""
template sendBa(station: uint8; context: pointer; action: uint8;
                token: uint8; params, status: uint16; fn: pointer) =
  when compiles(bam_send_air_action_frame(station, context, action, token, params, status, fn)):
    bam_send_air_action_frame(station, context, action, token, params, status, fn)
  else:
    bam_send_air_action_frame(station, cast[uint8](cast[uint](context)), action,
                              token, params, status.uint8, fn)

for station in 0'u8 .. 6'u8:
  for mode in [0'u8, 1, 2, 3]:
    for protection in [0'u32, 1, 2]:
      reset()
      let vif = addr vifs[stas[station].instNbr]
      vif.vifType = mode
      stas[station].wrongMode = if mode == 2: 0 else: 2
      var context = 0x1234'u32
      mfp = protection
      sendBa(station, addr context, 1, 0x79, 0x02DA, 0x1234, cast[pointer](callback))
      doAssert allocations == 1 and pushes == 1 and powerUpdates == 1
      let h = hostTxDataHeader(addr desc)
      doAssert h.addr1 == stas[station].macAddr and h.addr2 == vif.macAddr
      doAssert h.addr3 == (if mode == 2: vif.macAddr else: stas[station].macAddr),
        "Block Ack BSSID comes from station memory instead of VIF mode"
      doAssert h.seqCtrl == 0
      doAssert desc.staInfoIdx == station and desc.vifIdx == stas[station].instNbr
      doAssert desc.callback == cast[pointer](callback)
      doAssert desc.callbackArg == cast[pointer](addr context), "BA context pointer truncated"
      let extra = if protection == 1: 8 else: 0
      doAssert h.frameControl == (if extra != 0: 0x40D0'u16 else: 0xD0'u16)
      let body = addBaRspActionBodyAt(addr link.macHeader[24 + extra])
      doAssert body.category == 3 and body.action == 1 and body.dialogToken == 0x79
      doAssert body.baParams == 0x02DA and body.statusCode == 0x1234,
        "Block Ack response parameters or 16-bit status are corrupted"
      doAssert body.timeout == 0
      let total = 24 + extra + 9 + extra
      doAssert hw.frameLen == total.uint32 + 4
      doAssert hw.payloadEnd == hw.payloadStart + total.uint32 - 1
      for i in (24 + extra + 9) ..< link.macHeader.len:
        doAssert link.macHeader[i] == 0xA5
      for b in link.before: doAssert b == 0xA5
      for b in link.after: doAssert b == 0xA5
reset()
allocationFails = true
sendBa(0, nil, 1, 1, 2, 0, nil)
doAssert allocations == 1 and pushes == 0 and powerUpdates == 0
for action in [0'u8, 2, 3, 255]:
  reset()
  sendBa(0, nil, action, 1, 2, 0, nil)
  doAssert allocations == 0 and pushes == 0
for invalid in 0 .. 2:
  reset()
  var station = 0'u8
  case invalid
  of 0: station = 255
  of 1: stas[0].valid = 0
  else: stas[0].instNbr = 255
  sendBa(station, nil, 1, 1, 2, 0, nil)
  doAssert allocations == 0 and pushes == 0
""",
    "receive": r"""
for params in 0'u32 .. 65535'u32:
  reset()
  let station = (params mod 7).uint8
  let mode = ((params shr 3) and 2).uint8
  vifs[stas[station].instNbr].vifType = mode
  stas[station].wrongMode = mode
  var message: Message
  let p = request(message, station, params.uint16)
  doAssert rxu_mgt_ind_handler_bam(p) == 0
  doAssert allocations == 1 and pushes == 1
  doAssert mmio == 0xABCD0090'u32
  let body = addBaRspActionBodyAt(addr link.macHeader[24])
  let requestedWindow = params shr 6
  let acceptedWindow = min(requestedWindow, 12'u32)
  let expected = ((acceptedWindow shl 6) or (params and 0x3E) or 2).uint16
  doAssert body.baParams == expected, "ADDBA response loses TID/policy/window"
  doAssert body.statusCode == 0 and body.timeout == 0 and body.dialogToken == 0xEF
""",
    "malformed": r"""
for invalid in 0 .. 8:
  reset()
  var message: Message
  var p = request(message, 0, 0xFFFF)
  let view = rxuMgtDispatchView(p)
  case invalid
  of 0: p = nil
  of 1: view.category = 8
  of 2: view.frameCtrl = 0xB0
  of 3: view.staIdx = 255
  of 4: stas[0].valid = 0
  of 5: view.vifIdx = 1
  of 6: stas[0].instNbr = 255
  of 7: rxuMgtIndMsgAt(p).frameLen = 8
  else: rxuMgtIndMsgAt(p).frameLen = 37
  doAssert rxu_mgt_ind_handler_bam(p) == 0
  doAssert allocations == 0 and pushes == 0 and mmio == 0xABCD0010'u32
for size in 0'u32 .. 40'u32:
  reset()
  var message: Message
  let p = request(message, 0, 0xFFFF)
  message.header.paramLen = size
  doAssert rxu_mgt_ind_handler_bam(p) == 0
  doAssert allocations == 0 and pushes == 0
for action in [1'u8, 2, 3, 255]:
  reset()
  var message: Message
  let p = request(message, 0, 0xFFFF)
  rxuMgtDispatchView(p).actionCode = action
  doAssert rxu_mgt_ind_handler_bam(p) == 0
  doAssert allocations == 0 and pushes == 0
""",
    "initialization": r"""
reset()
for byte in bam_env.mitems: byte = 0xA5
bam_init()
doAssert stateCalls == 1
for i, byte in bam_env:
  doAssert byte == (if i == 12: 255'u8 else: 0xA5'u8)
""",
    "request_body": r"""
for tid in 0'u8 .. 15'u8:
  for policy in 0'u8 .. 1'u8:
    for window in [0'u8, 1, 12, 64, 255]:
      for ssn in [0'u16, 1, 4095, 65535]:
        var bytes: array[32, uint8]
        for byte in bytes.mitems: byte = 0xA5
        var env = MeAddBaReqParamView(ssn: ssn, timeout: 0xABCD,
          baPolicy: policy, bufferSize: window, tid: tid, dialogToken: 0xB7)
        doAssert me_build_add_ba_req(addr bytes[3], addr env) == 9
        let body = addBaReqActionBodyAt(addr bytes[3])
        doAssert body.category == 3 and body.action == 0 and body.dialogToken == 0xB7
        doAssert body.baParams == ((window.uint16 shl 6) or (tid.uint16 shl 2) or
                                   (policy.uint16 shl 1))
        doAssert body.timeout == 0xABCD and body.startSeq == (ssn shl 4)
        for i in 0 ..< 3: doAssert bytes[i] == 0xA5
        for i in 12 ..< bytes.len: doAssert bytes[i] == 0xA5
""",
}


@pytest.mark.parametrize("mode", CHECKS)
@pytest.mark.parametrize("release", [False, True])
def test_block_ack_responder(tmp_path: Path, mode: str, release: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["TxSessionIdentity", "RxuMgtDispatchView", "RxuMgtIndMsgView", "BamEnvView", "MeAddBaReqParamView",
                 "AddBaReqActionBodyView", "AddBaRspActionBodyView"]:
        match = re.search(r"(?ms)^  " + name + r"\b.*?(?=^  \w|\Z)", layout)
        assert match, name
        types += match.group(0)
    management = (FW / "scan_station_ap_me.nim").read_text()
    functions = procedure(management, "me_build_add_ba_req")
    functions += procedure(management, "me_build_add_ba_rsp")
    functions += procedure((FW / "block_ack.nim").read_text(), "bam_init")
    functions += procedure((FW / "block_ack.nim").read_text(), "bam_send_air_action_frame")
    functions += procedure((FW / "task_handlers.nim").read_text(), "rxu_mgt_ind_handler_bam")
    source = tmp_path / "block_ack.nim"
    source.write_text(types + PLATFORM + functions + CHECKS[mode])
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if release:
        command += ["-d:release"]
    command += ["--checks:on", f"--nimcache:{tmp_path / 'nimcache'}",
                f"-o:{tmp_path / 'test'}", str(source)]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
