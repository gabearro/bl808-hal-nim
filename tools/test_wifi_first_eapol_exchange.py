"""An activation-time M1 must reach WPA only when its reply can enter the STA queue."""

from pathlib import Path
import re

import pytest

import test_wifi_activation_exchange as activation
import test_wifi_eapol_routing as routing
import test_wifi_tx_submission as tx
from test_wifi_message_allocation import run_program


def rx_module():
    rx = routing.rx
    code = rx.dispatch_source()
    stub = rx.procedure(code, "sm_handle_eapol_input")
    code = code.replace(stub, routing.handler().split(" =\n", 1)[0] + "\n", 1)
    code = code.replace("    cipher: uint8", "    cipher, connected: uint8", 1)
    code = code.replace("proc smActivationEapolReady(vif, station: uint8): bool = true",
                        "var peerReady*: proc(vif, station: uint8): bool\n"
                        "proc smActivationEapolReady(vif, station: uint8): bool = peerReady(vif, station)")
    stub = rx.procedure(code, "smActivationRetainM1")
    code = code.replace(stub, """var retain*: proc(vif, station: uint8; source: array[6,uint8];
    data: pointer; available: uint32): bool
""" + stub.split(" =")[0] + " = retain(vif, station, source, data, available)\n", 1)
    code += routing.callback_types() + routing.SUPPORT + routing.handler()
    code += rx.CHECKS.split("# Unprotected IP", 1)[0]
    return code + """
proc deliver*(sta: uint8; source, data: pointer; length: uint16) =
  sm_handle_eapol_input(sta, source, data, length)
proc receive*(port: uint8; input: pointer; ip = false; kde = false;
              keyInfo = 0x8a'u8; differentSource = false) =
  let length = if kde: 121 else: 99
  setup(0x0208, 24, 8 + length, secure=true)
  resetRouting(9)
  wpa.eapolHandler = input
  vifs[0].security.connected = 1
  let frame = macDataFrameAt(addr bytes[0])
  frame.addr3 = frame.addr2
  if differentSource: inc frame.addr3[5]
  stations[0].macAddr = frame.addr2
  stations[0].controlPortState = port
  snapAt(24, if ip: 0x0800 else: 0x888e)
  for i in 32 ..< 32 + length: bytes[i] = 0
  bytes[32] = 2; bytes[33] = 3; bytes[35] = (length-4).uint8
  bytes[36] = 2; bytes[38] = keyInfo; bytes[40] = 16; bytes[48] = 1
  for i in 49..<81: bytes[i] = (i-48).uint8
  if kde:
    bytes[130] = 22
    for i, b in [0xdd'u8, 20, 0, 0x0f, 0xac, 4]: bytes[131+i] = b
  doAssert rxu_cntrl_frame_handle(addr mpdu) == 0 and transferred == 0
  for b in bytes.mitems: b = 0xee
"""


def host_module():
    # Use native-width TX headers/list pointers. Map the host byte offsets used
    # by the real station-add handler onto these same (not duplicate) tables.
    code = tx.prelude().replace("PbufLinkEncapsulationHlen = 48", "PbufLinkEncapsulationHlen = 64")
    code += """
proc bl_tx_try_flush*(param: cint; txFcField: ptr KeTxFc) = discard
type BlSta = object
type BlTxCfm = object
var acknowledge*: proc(p: pointer; vif, station: uint8; linked: bool): bool
var track*: proc(p, hw: pointer; token: uint32;
    check: proc(host: pointer; station: uint8; token: uint32; retire: bool): bool {.nimcall.})
var stationRxSerial*: uint32
const PsModeOff = 0'u8
proc callbackIrqSave(): uint32 = ipcHostIrqSave()
proc callbackIrqRestore(flags: uint32) = ipcHostIrqRestore(flags)
proc msgParam(p: pointer): pointer = cast[pointer](cast[uint](p)+8)
proc vifAt(hw: pointer; idx: int): pointer = vifAt(idx)
proc staAt(hw: pointer; idx: uint): pointer = staAt(idx.int)
type Transition = tuple[valid: bool, fixedStation: uint8, serial: uint32]
proc beginStationRxTransition(hw: pointer; station: uint8): Transition =
  inc stationRxSerial
  (true, station, stationRxSerial)
proc stationRxTransitionCurrent(t: Transition): bool = t.valid and t.serial == stationRxSerial
proc bl_tx_cntrl_link_up(s: ptr BlSta) = discard
proc bl_tx_cntrl_link_down(s: ptr BlSta) = discard
proc nativeLoad(p: pointer; off: uint): uint8 = cast[ptr uint8](cast[uint](p)+off)[]
proc nativeStore(p: pointer; off: uint; v: uint8) = cast[ptr uint8](cast[uint](p)+off)[] = v
proc c_memcmp(a,b:pointer; n:csize_t): cint {.importc:"memcmp",header:"<string.h>".}
template bl_os_printf(fmt: cstring; first: untyped; a: varargs[untyped]) = discard
proc pbuf_header(p: ptr Pbuf; n: int16): uint8 =
  let v = pbufView(p)
  v.payload = cast[pointer](cast[uint](v.payload)-n.uint)
  v.totLen += n.uint16
proc pbuf_ref(p: ptr Pbuf) = discard
{.emit: "volatile unsigned int nimfw_dbg_bl_output_drop;".}
"""
    body = (tx.TX.parent / "rx/station_events_parts/sta_add.nim").read_text()
    body = body.replace("firmware.smActivationAcceptPeer", "acknowledge").replace(
        "acknowledge(ind, firmwareVif, station)", "acknowledge(ind, firmwareVif, station, false)")
    body = body.replace("firmware.smActivationTrackPeer", "track").replace(
        "BlVifStaPsOff", "offsetof(BlVifView, staPsMode).uint")
    body = body.replace("loadU8(", "nativeLoad(").replace("storeU8(", "nativeStore(")
    for prefix, fields in [("Vif", ["linksNum", "fixedStaIdx", "fcChan", "vifIdx"]),
                           ("Sta", ["isUsed", "staIdx", "vifIdx", "qos", "fcPs"])]:
        for field in fields:
            body = body.replace(f"Bl{prefix}{field[0].upper() + field[1:]}Off",
                                f"offsetof(Bl{prefix}View, {field}).uint")
    body = body.replace("SmStaAddApIdxOff", "1'u").replace("SmStaAddQosOff", "2'u")
    body += (tx.TX / "queue_parts/station_lookup.nim").read_text()
    body += (tx.TX / "output_parts/enqueue.nim").read_text()
    code += "".join(f"var {v}: uint32\n" for v in sorted(set(re.findall(r"\bnimFwDbg\w+", body))))
    return code + body + """
proc resetPeer*() =
  wifi_hw = default(BlHwView)
  txCntrlStaTrigger = 0
proc publish*(p: pointer) =
  doAssert blRxSmStaAddInd(addr wifi_hw, nil, cast[pointer](cast[uint](p)-8)) == 0
proc peerLinked*(): bool = txCntrlGetStaId(1, false, nil) == 0
proc reply*(source: pointer) =
  let eth = ethernetHeaderAt(addr packetBytes[0][PbufLinkEncapsulationHlen])
  system.copyMem(addr eth.dst[0], source, 6)
  eth.ethertype = 0x8e88
  eth.payload[0] = 2; eth.payload[1] = 3; eth.payload[3] = 95
  eth.payload[4] = 2; eth.payload[5] = 1; eth.payload[6] = 0x0a
  packets[0] = PbufView(payload: eth, totLen: 113, len: 113)
  doAssert enqueueTxPacket(1, cast[ptr Pbuf](addr packets[0]), addr packets[0], eth, nil) == ErrOk
  doAssert listPopFront(addr wifi_hw.stas[0].waitingList) == addr packetBytes[0][0]
  doAssert txCntrlStaTrigger == 1
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_m1_to_sta_tx_queue(tmp_path: Path, mode: str):
    (tmp_path / "wparx.nim").write_text(rx_module())
    (tmp_path / "wpatx.nim").write_text(host_module())
    run_program(tmp_path, mode, "import wparx, wpatx\n" + activation.source() + """
var replies, expectedLength: int
proc wpa(source, data: pointer; n: uint32): cint {.cdecl.} =
  doAssert enabled and n.int == expectedLength and stations[0].controlPortState == 1
  doAssert cast[ptr array[6,uint8]](source)[] == stations[0].macAddr
  let key = cast[ptr UncheckedArray[uint8]](data)
  doAssert key[1] == 3 and key[6] == 0x8a and key[16] == 1 and key[48] == 32
  wpatx.reply(source)
  inc replies
wparx.retain = smActivationRetainM1
wparx.peerReady = smActivationEapolReady
wpatx.acknowledge = smActivationAcceptPeer
wpatx.track = smActivationTrackPeer
for timing in 0..7: # before/during/after link-up; rekey, replacement, reset, reuse, cleanup
  for kde in [false, true]:
    setup(0, 0, cipher=3)
    wpatx.resetPeer()
    replies = 0
    expectedLength = if kde: 121 else: 99
    stations[0].macAddr = [4'u8, 6, 7, 8, 9, 10]
    vifs[0].security.connected = 1
    vifs[0].security.keyMgmt = WifiKeyMgmtPsk
    onEapol = wparx.deliver
    onPeer = proc(p: pointer) =
      if timing == 1: wparx.receive(stations[0].controlPortState, cast[pointer](wpa), kde=kde)
      doAssert replies == 0
      wpatx.publish(p)
    sm_assoc_done(7)
    wparx.receive(stations[0].controlPortState, cast[pointer](wpa), ip=true)
    wparx.receive(0, cast[pointer](wpa), keyInfo=0x0a)
    wparx.receive(0, cast[pointer](wpa), differentSource=true)
    doAssert smActivation.firstM1.length == 0
    if timing in [0, 3, 4]:
      for retry in 0..1: wparx.receive(stations[0].controlPortState, cast[pointer](wpa), kde=kde)
      doAssert replies == 0
    let cfm = takeReply(0)
    if timing == 3: inc rxKeyLastChanged[0]
    if timing == 4: replaceOwner()
    consumeReply(cfm)
    ke_msg_free(keMsgHdrFromPayload(cfm))
    if timing == 2: wparx.receive(stations[0].controlPortState, cast[pointer](wpa), kde=kde)
    wparx.receive(stations[0].controlPortState, cast[pointer](wpa), ip=true)
    doAssert replies == int(timing < 3) and connected == 0
    if timing in [5, 6]:
      doAssert wpatx.peerLinked()
      if timing == 6:
        inc wpatx.stationRxSerial
        wparx.receive(stations[0].controlPortState, cast[pointer](wpa), kde=kde)
        doAssert replies == 0
      smActivationCancel()
      doAssert wpatx.peerLinked() == (timing == 6)
      doAssert stations[0].controlPortState == 0
    if timing == 7:
      # The attempt's teardown withdraws the peer published early.
      smActivationCancel()
      doAssert not wpatx.peerLinked()
    drain()
    finish()
    if timing < 4: doAssert wpatx.peerLinked()
""")
