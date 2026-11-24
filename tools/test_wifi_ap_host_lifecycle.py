"""Exercise the real AP host lifecycle with fake firmware confirmations."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  Netif = object
    when defined(bl808WifiRealLwip):
      prefix: array[64, uint8] # Deliberately not the legacy layout.
    else:
      prefix: array[58, uint8]
    hwaddr: array[6, uint8]
    name: array[2, uint8]
  Ip4Addr = uint32
  MmAddIfCfm = array[2, uint8]
  ApmStartCfm = array[4, uint8]
const
  BlVifSta = 0'u
  BlVifAp = 1'u
  NxVirtDevMax = 2'u
  BlVifDevOff = 0'u
  BlVifUpOff = 8'u
  BlVifVifIdxOff = 9'u
  BlVifLinksNumOff = 10'u
  BlVifFixedStaIdxOff = 11'u
  BlVifSize = 16'u
  BlStaVifIdxOff = 0'u
  BlStaStaIdxOff = 1'u
  BlStaQosOff = 2'u
  NxRemoteStaStoreMax = 7'u
  WifiIfaceMacOff = 5'u
  WifiIfaceVifIndexOff = 4'u
  WifiIfaceModeOff = 0'u
  MgmrApBcnIntOff = 0'u
  NetifHwaddrOff = 58'u
  NetifNameOff = 64'u
  CoOk = 0'u8
  Eio = 5.cint
  Nl80211IftypeStation = 2.cint
  Nl80211IftypeAp = 3.cint
var
  vifs: array[2, array[BlVifSize.int, uint8]]
  stations: array[7, array[3, uint8]]
  staNetif, apNetif: Netif
  apInterface: array[12, uint8]
  interval = 100'u16
  staEnabled = true
  apEnabled, apRegistered, busy, linked, netifPresent: bool
  failNetif, noStartCfm: bool
  fwAddStatus, fwStartStatus, fwStartVif: uint8
  addRc, startRc, stopRc, removeRc: cint
  calls: seq[string]
proc ptrAt(p: pointer; offset: uint): pointer = cast[pointer](cast[uint](p) + offset)
proc zero(p: pointer; size: int) = zeroMem(p, size)
proc loadU8(p: pointer; offset: uint): uint8 = cast[ptr uint8](ptrAt(p, offset))[]
proc loadU16(p: pointer; offset: uint): uint16 = cast[ptr uint16](ptrAt(p, offset))[]
proc storeU8(p: pointer; offset: uint; v: uint8) = cast[ptr uint8](ptrAt(p, offset))[] = v
proc storeI32(p: pointer; offset: uint; v: int32) = cast[ptr int32](ptrAt(p, offset))[] = v
proc storePtr(p: pointer; offset: uint; value: pointer) = cast[ptr pointer](ptrAt(p, offset))[] = value
proc hwPtr(): pointer = nil
proc vifAt(i: uint): pointer = addr vifs[i][0]
proc staAt(i: uint): pointer = addr stations[i][0]
proc mgmrRaw(): pointer = addr interval
proc apIface(): pointer = addr apInterface[0]
proc staIface(): pointer = addr staNetif
proc ifaceNetif(p: pointer): pointer =
  if p == apIface(): addr apNetif else: addr staNetif
proc netifHwaddr(p: pointer): ptr uint8 = addr cast[ptr Netif](p).hwaddr[0]
proc realNetifSetName(p: ptr Netif; a, b: char) =
  p.name = [a.uint8, b.uint8]
proc beginStationControl(): bool =
  if busy: return false
  busy = true
  true
proc endStationControl() = busy = false
proc bl606a0_wifi_netif_init() = discard
proc tcpip_input() = discard
proc netifapi_netif_add(n: ptr Netif; ip, mask, gw: ptr Ip4Addr;
                      state: pointer; init, input: proc()): int8 =
  doAssert n == (addr apNetif) and not netifPresent
  doAssert ip[] == 0x010BA8C0'u32 and mask[] == 0x00FFFFFF'u32 and gw[] == 0
  calls.add("netif add")
  if failNetif: return -1
  netifPresent = true
  0
proc netifapi_netif_set_addr(n: ptr Netif; ip, mask, gw: ptr Ip4Addr): int8 = 0
proc wifiRemoveApNetif(n: ptr Netif) =
  doAssert n == (addr apNetif) and netifPresent
  calls.add("netif remove")
  netifPresent = false
proc netif_set_up(n: ptr Netif) = calls.add("up")
proc netif_set_link_up(n: ptr Netif) =
  doAssert apEnabled and apRegistered
  calls.add("link up")
  linked = true
proc netif_set_link_down(n: ptr Netif) =
  calls.add("link down")
  linked = false
proc bl_send_add_if(hw: pointer; mac: ptr uint8; role: cint;
                    p2p: bool; cfm: ptr MmAddIfCfm): cint =
  doAssert role == Nl80211IftypeAp and not p2p and netifPresent
  doAssert mac == addr apNetif.hwaddr[0]
  doAssert apNetif.hwaddr == [2'u8, 4, 6, 8, 10, 13]
  calls.add("add AP VIF")
  # Host slot 1 is mapped to firmware slot 0. STA already has firmware slot 1.
  cfm[] = [fwAddStatus, 0'u8]
  addRc
proc bl_send_remove_if(hw: pointer; i: uint8): cint =
  doAssert i == 0 and netifPresent
  calls.add("remove AP VIF")
  removeRc
proc bl_msg_get_channel_nums(): cint = 11
proc bl_send_apm_start_req(hw: pointer; cfm: ptr ApmStartCfm;
                           ssid, password: cstring; channel: cint;
                           i, hidden: uint8; bcnInt: uint16): cint =
  doAssert i == 0 and channel == 11 and not linked and apRegistered
  calls.add("start")
  if not noStartCfm: cfm[] = [fwStartStatus, fwStartVif, 0'u8, 5'u8]
  startRc
proc bl_send_apm_stop_req(hw: pointer; i: uint8): cint =
  doAssert i == 0 and apRegistered
  calls.add("stop")
  stopRc
'''


CHECKS = r'''
staNetif.hwaddr = [2'u8, 4, 6, 8, 10, 12]
vifs[0][BlVifUpOff] = 1
vifs[0][BlVifVifIdxOff] = 1
let initialSta = vifs[0]
proc start(): cint = wifi_mgmr_ap_start(nil, "setup", 0, "test-only", 11)
proc stop(): cint = wifi_mgmr_ap_stop(nil)
proc assertUnregistered() =
  doAssert not apEnabled and not apRegistered and not netifPresent and not linked and not busy
  doAssert wifi_mgmr_ap_netif_get() == nil
  doAssert vifs[0] == initialSta and vifs[1] == default(typeof(vifs[1]))

doAssert bl_main_apm_start("setup", "test-only", 11, 0, 100) == -Eio
doAssert calls.len == 0
for mode in 0..5:
  failNetif = mode == 0
  addRc = if mode == 1: -12 else: 0
  fwAddStatus = if mode == 2: 4 else: 0
  startRc = if mode == 3: -110 else: 0
  fwStartStatus = if mode == 4: 4 else: 0
  noStartCfm = mode == 5
  calls.setLen(0)
  doAssert start() != 0
  assertUnregistered()
  if mode >= 3:
    doAssert calls == @["netif add", "add AP VIF", "start", "remove AP VIF", "netif remove"]
  else: doAssert "start" notin calls
  doAssert stations[5][BlStaQosOff] == 0 and stations[0][BlStaQosOff] == 0
noStartCfm = false
fwStartVif = 1
doAssert start() == -Eio
assertUnregistered()
fwStartVif = 0
calls.setLen(0)
doAssert start() == 0 and wifi_mgmr_ap_netif_get() == addr apNetif
doAssert calls == @["netif add", "add AP VIF", "start", "up", "link up"]
doAssert vifs[1][BlVifVifIdxOff] == 0 and apInterface[WifiIfaceVifIndexOff] == 1
doAssert stations[5] == [1'u8, 5, 1]
doAssert start() == -16 and calls.len == 5
stopRc = -110
doAssert stop() == -110 and linked and apEnabled and apRegistered
stopRc = 0
removeRc = -110
doAssert stop() == -110 and not linked and not apEnabled and apRegistered
doAssert wifi_mgmr_ap_netif_get() == nil and vifs[1][BlVifUpOff] != 0
removeRc = 0
calls.setLen(0)
doAssert stop() == 0 and calls == @["remove AP VIF", "netif remove"]
assertUnregistered()
doAssert start() == 0 and stop() == 0
assertUnregistered()
'''


@pytest.mark.parametrize("mode", ["checked", "firmware"])
@pytest.mark.parametrize("real_lwip", [False, True], ids=["legacy", "real-lwip"])
def test_ap_host_interface_registration_and_confirmations(
    tmp_path: Path, mode: str, real_lwip: bool
) -> None:
    wifi = ROOT / "src/bl808/wifi"
    host = wifi / "main/host_ops_parts"
    interfaces = (host / "interface_management.nim").read_text()
    ap = (host / "ap_management.nim").read_text()
    manager = wifi / "support/mgmr_facade_parts"
    code = PLATFORM + "\n" + (wifi / "main/layout_parts/confirmations.nim").read_text()
    code += procedure((wifi / "main/accessors.nim").read_text(), "netifHwaddr")
    for name in ["bl_main_if_remove", "bl_main_if_add"]:
        code += procedure(interfaces, name)
    for name in ["bl_main_apm_start", "bl_main_apm_stop"]:
        code += procedure(ap, name)
    code += (manager / "ap_control.nim").read_text()
    code += procedure((manager / "station_interface.nim").read_text(), "wifi_mgmr_ap_netif_get")
    defines = ("bl808WifiRealLwip",) if real_lwip else ()
    run_program(tmp_path, mode, code + CHECKS, defines=defines)
