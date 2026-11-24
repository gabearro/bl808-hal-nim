"""Exercise copied RX delivery across firmware and host lifetime changes."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_rx_copy import CHECKS as COPY_CHECKS, source as copy_source

FW = ROOT / "src/bl808/wifi/fw"
UTILS = ROOT / "src/bl808/wifi/utils"

CONTEXT = r"""
{.pragma: wifiCtrl.}
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  STA_MGMT_FREE_STAS = 5
  HostScale = sizeof(pointer).uint div 4
type
  RxStationIdentity = object
    epoch: uint32
    vifEpochs: array[MAX_VIFS, uint32]
    keyRevision: uint64
    station, vif: uint8
    captured, associated: bool
  Station = object
    valid, instNbr: uint8
  NetifInput = proc(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.}
  Netif = object
    input: NetifInput
  KeTxFc = object
  BlRxInfo = object
    rssi: int8
    legRate, formatMod: uint8
var
  wifi_hw: array[1024, uint8]
  hwHeader: array[64, uint8]
  interfaces: array[2, Netif]
  descriptors: array[2, uint32]
  stations: array[7, Station]
  epochs: array[7, uint32]
  rxStationIdentities: array[41, RxStationIdentity]
  rxUploadEpochs: array[41, uint32]
  rxVifEpochs: array[MAX_VIFS, uint32]
  rxKeyRevision = 1'u64
  incoming: bool
  received: seq[seq[uint8]]
  wrongInput: int
  onInput: proc()
  rejectInput: bool
  retirementAllocations: int
proc rxMpduDescIndex(p: pointer): int =
  for i in 0 ..< descriptors.len:
    if p == addr descriptors[i]: return i
  -1
proc staInfoForIdx(i: uint8): ptr Station = addr stations[i]
proc staDeleteEpoch(i: uint8): uint32 = epochs[i]
proc irqSave(): uint32 =
  result = csrReadMstatus().uint32
  disableInterrupts()
proc irqRestore(saved: uint32) =
  if (saved and 8) != 0: enableInterrupts()
proc loadPtr(p: pointer; offset: uint): pointer = cast[ptr pointer](ptrAt(p, offset))[]
proc storePtr(p: pointer; offset: uint; value: pointer) =
  cast[ptr pointer](ptrAt(p, offset))[] = value
proc storeU8(p: pointer; offset: uint; value: uint8) =
  cast[ptr uint8](ptrAt(p, offset))[] = value
proc noteEthernetInput(p: ptr Pbuf): bool = false
proc ke_msg_send(p: pointer) = doAssert false, "unexpected station indication"
proc pbuf_take_at(p: ptr Pbuf; data: pointer; length, offset: uint16): int8 =
  doAssert offset.uint32 + length.uint32 <= p.len.uint32
  let source = if cast[uint](data) < 0x50000: resolve(data, length.uint) else: data
  copyMem(cast[pointer](cast[uint](p.payload) + offset.uint), source, length.int)
  0
proc bl808_nim_netif_input_call(p: ptr Pbuf; netif: ptr Netif): int8 =
  if netif == nil or netif.input == nil: return -1
  netif.input(p, netif)
proc deliver(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.} =
  doAssert enabled == incoming, "network callback IRQ state changed"
  doAssert netif == addr interfaces[0]
  if rejectInput: return -1
  var bytes: seq[uint8]
  var current = p
  while current != nil:
    for i in 0 ..< current.len.int:
      bytes.add(cast[ptr UncheckedArray[uint8]](current.payload)[i])
    current = current.next
  received.add(bytes)
  discard pbuf_free(p)
  if onInput != nil:
    let action = onInput
    onInput = nil
    action()
  0
proc replacement(p: ptr Pbuf; netif: ptr Netif): int8 {.cdecl.} =
  inc wrongInput
  discard pbuf_free(p)
  0
proc bl_rx_pkt_cb(data: ptr uint8; length: cint; wrapper: pointer; info: ptr BlRxInfo) =
  doAssert enabled == incoming
  var bytes: seq[uint8]
  for i in 0 ..< length: bytes.add(cast[ptr UncheckedArray[uint8]](data)[i])
  received.add(bytes)
  if onInput != nil:
    let action = onInput
    onInput = nil
    action()
proc tcpip_stack_input*(swdesc: pointer; status: uint32; hwhdr: pointer;
                        msduOffset: uint32; pkt: pointer;
                        extraStatus: uint32): cint {.exportc, cdecl.}
"""

CHECKS = r"""
proc hostVif(): pointer = ptrAt(addr wifi_hw[0], BlHwVifTableOff)
proc prepareHandoff(state = true) =
  prepare(128)
  incoming = state
  enabled = state
  wifi_hw = default(typeof(wifi_hw))
  hwHeader = default(typeof(hwHeader))
  interfaces = default(typeof(interfaces))
  rxStationIdentities = default(typeof(rxStationIdentities))
  rxUploadEpochs = default(typeof(rxUploadEpochs))
  rxVifEpochs = default(typeof(rxVifEpochs))
  epochs = default(typeof(epochs))
  stations = default(typeof(stations))
  received.setLen(0)
  wrongInput = 0
  onInput = nil
  rejectInput = false
  retirementAllocations = -1
  stations[0] = Station(valid: 1, instNbr: 0)
  for i in 0 .. 1:
    rxUploadEpochs[i] = 1
    rxStationIdentities[i] = RxStationIdentity(captured: true,
      associated: true, station: 0, vif: 0, epoch: 0)
  interfaces[0].input = deliver
  interfaces[1].input = replacement
  storeU8(ptrAt(addr wifi_hw[0], BlHwStaTableOff), BlStaVifIdxOff, 0)
  storeU8(hostVif(), BlVifUpOff, 1)
  storePtr(hostVif(), BlVifDevOff, addr interfaces[0])
proc retire(kind: int) =
  retirementAllocations = allocations
  case kind
  of 0: inc rxUploadEpochs[0]
  of 1: inc epochs[0]
  of 2: inc rxVifEpochs[0]
  of 3: stations[0].valid = 0
  of 4: storeU8(hostVif(), BlVifUpOff, 0)
  of 5: storePtr(hostVif(), BlVifDevOff, addr interfaces[1])
  of 6: interfaces[0].input = replacement
  else:
    inc rxUploadEpochs[0]
    inc rxVifEpochs[0]
    storeU8(hostVif(), BlVifUpOff, 0)
    storeU8(hostVif(), BlVifUpOff, 1)
proc runInput(aggregate = false; slot = 0): cint =
  rxHostForward(addr descriptors[slot], rxUploadEpochs[slot], 1,
                addr hwHeader[0], 0, addr packet,
                if aggregate: BlRxStatusAmsdu else: 0'u32)
proc aggregateBytes(): seq[uint8] =
  for frame in 0 .. 1:
    for i in 0 ..< 12: result.add((i * 2 + 2).uint8)
    result.add(0)
    result.add(8)
    for i in 0 ..< 8: result.add((frame * 20 + i + 1).uint8)
    if frame == 0:
      result.add(0)
      result.add(0)
proc prepareAggregate(state: bool) =
  prepareHandoff(state)
  expected = aggregateBytes()
  packet.lengths[0] = expected.len.uint16
  for i, value in expected: buffers[0][i] = value

when TestCase == "normal":
  for state in [false, true]:
    prepareHandoff(state)
    doAssert runInput() == 0
    doAssert received == @[expected] and outstanding == 0 and enabled == state
elif TestCase == "copy_reset":
  for kind in 0 .. 7:
    prepareHandoff()
    onAllocate = proc() = retire(kind)
    doAssert runInput() == -1, "accepted a retired RX delivery"
    doAssert received.len == 0 and wrongInput == 0 and outstanding == 0
elif TestCase == "aggregate_normal":
  for state in [false, true]:
    prepareAggregate(state)
    doAssert runInput(true) == 0
    doAssert received.len == 2 and outstanding == 0 and enabled == state
elif TestCase == "aggregate_reset":
  for state in [false, true]:
    for kind in 0 .. 7:
      prepareAggregate(state)
      onInput = proc() = retire(kind)
      doAssert runInput(true) == -1, "aggregate continued into a new RX session"
      doAssert received.len == 1 and wrongInput == 0 and outstanding == 0
      doAssert allocations == retirementAllocations, "allocated after RX retirement"
elif TestCase == "input_failure":
  prepareHandoff()
  rejectInput = true
  doAssert runInput() == -1
  doAssert received.len == 0 and outstanding == 0
elif TestCase == "scope_end":
  prepareHandoff()
  var captured: RxHostLease
  onInput = proc() =
    captured = rxHostActiveUpload.lease
    doAssert rxHostLeaseCurrent(captured)
  doAssert runInput() == 0
  doAssert not rxHostLeaseCurrent(captured), "RX lease survived its dispatch"
  doAssert rxHostActiveUpload == nil
elif TestCase == "duplicate":
  for direct in [false, true]:
    prepareHandoff()
    onInput = proc() =
      let nested = if direct:
        tcpip_stack_input(addr descriptors[0], 1, addr hwHeader[0], 0, addr packet, 0)
      else: runInput()
      doAssert nested == -1, "RX upload was consumed twice"
    doAssert runInput() == 0
    doAssert received.len == 1 and outstanding == 0
elif TestCase == "nested":
  prepareAggregate(true)
  onInput = proc() = doAssert runInput(false, 1) == 0
  doAssert runInput(true) == 0
  doAssert received.len == 3 and outstanding == 0 and rxHostActiveUpload == nil
elif TestCase == "nested_reuse":
  prepareAggregate(true)
  onInput = proc() =
    inc rxUploadEpochs[0]
    doAssert runInput(false) == 0
  doAssert runInput(true) == -1
  doAssert received.len == 2 and outstanding == 0 and rxHostActiveUpload == nil
elif TestCase == "ancestor":
  prepareHandoff()
  pending = proc() =
    onInput = proc() =
      doAssert tcpip_stack_input(addr descriptors[0], 1, addr hwHeader[0], 0, addr packet, 0) == -1
    doAssert runInput(false, 1) == 0
  doAssert runInput() == 0
  doAssert received.len == 2 and outstanding == 0 and rxHostActiveUpload == nil
elif TestCase == "unregistered":
  for state in [false, true]:
    prepareHandoff(state)
    doAssert tcpip_stack_input(addr descriptors[0], 1, addr hwHeader[0], 0, addr packet, 0) == -1
    doAssert rxHostForward(nil, 0, 1, addr hwHeader[0], 0, addr packet, 0) == -1
    doAssert outstanding == 0 and allocations == 0 and enabled == state
elif TestCase == "entry_reset":
  prepareHandoff()
  pending = proc() = retire(0)
  doAssert runInput() == -1
  doAssert received.len == 0 and allocations == 0 and outstanding == 0
elif TestCase == "no_input":
  prepareHandoff()
  interfaces[0].input = nil
  doAssert runInput() == -1
  doAssert allocations == 0 and outstanding == 0
elif TestCase == "monitor":
  for state in [false, true]:
    prepareHandoff(state)
    hwHeader[0] = 128
    hwHeader[48] = 2
    doAssert runInput() == 0
    doAssert received == @[expected] and outstanding == 0 and enabled == state
elif TestCase == "monitor_reset":
  for kind in [0, 1, 2, 3, 7]:
    prepareHandoff()
    hwHeader[0] = 128
    hwHeader[48] = 2
    onAllocate = proc() = retire(kind)
    doAssert runInput() == -1
    doAssert received.len == 0 and outstanding == 0
elif TestCase == "monitor_unbound":
  prepareHandoff()
  rxStationIdentities[0] = RxStationIdentity(captured: true, station: 0xFF, vif: 0xFF)
  hwHeader[0] = 128
  hwHeader[48] = 2
  onAllocate = proc() = inc rxVifEpochs[0]
  doAssert runInput() == 0
  doAssert received == @[expected] and outstanding == 0
"""


MUTANTS = {
    "generation": "copy_reset", "identity": "copy_reset", "scope": "scope_end",
    "claim": "duplicate", "duplicate": "duplicate", "host_vif": "copy_reset",
    "netif": "copy_reset", "callback": "copy_reset", "deliver": "copy_reset",
    "amsdu": "aggregate_reset", "monitor": "monitor_reset",
    "ancestor": "ancestor",
}


def program(case: str, mutation: str | None = None) -> str:
    source = copy_source("copy").removesuffix(COPY_CHECKS["copy"])
    source = (f'from "{UTILS.parent / "host_table_layout"}" import '
              f'WifiHostStaTableOffset, WifiHostStaEntrySize, WifiHostStaTableCount\n' + source)
    source = source.replace(
        "proc ptrAt(p: pointer; offset: uint): pointer = cast[pointer](cast[uint](p) + offset)",
        "var hostStart, hostEnd: uint\n"
        "proc ptrAt(p: pointer; offset: uint): pointer =\n"
        "  let address = cast[uint](p)\n"
        "  let factor = if address >= hostStart and address < hostEnd: sizeof(pointer).uint div 4 else: 1'u\n"
        "  cast[pointer](address + offset * factor)",
    )
    source = source.replace(
        "  else:\n    result = cast[ptr uint8](resolve(ptrAt(p, offset), 1))[]",
        "  elif cast[uint](p) >= 0x1_0000_0000'u:\n"
        "    result = cast[ptr uint8](ptrAt(p, offset))[]\n"
        "  else:\n    result = cast[ptr uint8](resolve(ptrAt(p, offset), 1))[]",
    )
    layout = (UTILS / "layout.nim").read_text()
    constants = re.findall(r"^  (\w+) = (.+)$", layout, re.MULTILINE)
    source += "\nconst\n" + "".join(
        f"  {name} = {value}\n" for name, value in constants
        if not re.search(rf"^  {name} =", source, re.MULTILINE)
    )
    source += CONTEXT
    lower = (FW / "rx_layer.nim").read_text()
    for name in ["rxUploadGeneration", "rxUploadCurrent", "rxIdentityCurrent", "rxStationCurrent"]:
        source += procedure(lower, name)
    bridge = FW / "rx_host_delivery.nim"
    if bridge.exists():
        source += bridge.read_text()
    else:
        source += r"""
proc rxHostForward(desc: pointer; generation, status: uint32; header: pointer;
                   offset: uint32; data: pointer; extra: uint32): cint =
  tcpip_stack_input(desc, status, header, offset, data, extra)
"""
    source += (UTILS / "tcpip_pbuf_diag_parts/vif_lookup.nim").read_text()
    delivery = UTILS / "rx_delivery.nim"
    body = delivery.read_text().replace("firmware.", "") if delivery.exists() else ""
    body += (UTILS / "monitor_input.nim").read_text().replace("firmware.", "")
    body += (UTILS / "tcpip_pbuf_alloc_parts/amsdu_input.nim").read_text()
    body += (UTILS / "tcpip_input.nim").read_text().replace("firmware.", "")
    existing = set(re.findall(r"\bnimFwDbg\w+", source))
    names = set(re.findall(r"\bnimFwDbg\w+", body)) - existing
    if names: source += "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(names))
    source += body
    if mutation:
        name = {"generation": "rxHostLeaseCurrent", "identity": "rxHostLeaseCurrent",
                "scope": "rxHostLeaseCurrent", "claim": "captureRxHostLease",
                "duplicate": "rxHostForward", "host_vif": "rxDeliveryCurrent",
                "netif": "rxDeliveryCurrent", "callback": "rxDeliveryCurrent",
                "deliver": "deliverRxPacket", "amsdu": "inputAmsdu",
                "monitor": "inputMonitorFrame", "ancestor": "captureRxHostLease"}[mutation]
        old = procedure(source, name)
        new = old
        if mutation == "generation":
            new = old.replace("not rxUploadCurrent(lease.descriptor, lease.generation)", "false")
        elif mutation == "identity":
            new = old.replace("not rxIdentityCurrent(lease.identity)", "false")
        elif mutation == "scope":
            new = old.split("  var scope = rxHostActiveUpload", 1)[0] + "  true\n"
        elif mutation == "claim":
            new = old.replace("scope.claimed or ", "")
        elif mutation == "duplicate":
            start = old.index("    var active = rxHostActiveUpload")
            end = old.index("    inc rxHostUploadSerial", start)
            new = old[:start] + old[end:]
        elif mutation == "host_vif":
            new = old.replace("rxVif(cast[pointer](addr wifi_hw), delivery.station) == delivery.vif", "true")
        elif mutation == "netif":
            new = old.replace("loadPtr(delivery.vif, BlVifDevOff) == cast[pointer](delivery.netif)", "true")
        elif mutation == "callback":
            new = old.replace("delivery.netif.input == delivery.input", "true")
        elif mutation == "deliver":
            new = old.replace("if not current:", "if false:")
        elif mutation == "amsdu":
            new = old.replace("if not rxDeliveryCurrent(delivery):", "if false:")
        elif mutation == "monitor":
            new = old.replace("if lease != nil and not rxHostLeaseCurrent(lease[]):", "if false:")
        elif mutation == "ancestor":
            new = old.replace("  let scope = rxHostActiveUpload\n", "  var scope = rxHostActiveUpload\n"
                "  while scope != nil and scope.lease.descriptor != descriptor:\n"
                "    scope = scope.previous\n")
        assert old != new
        source = source.replace(old, new)
    return source + f'\nconst TestCase = "{case}"\n' + CHECKS


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", ["normal", "copy_reset", "aggregate_normal", "aggregate_reset", "input_failure",
                                  "scope_end", "duplicate", "nested", "nested_reuse", "unregistered",
                                  "entry_reset", "no_input", "monitor", "monitor_reset", "monitor_unbound",
                                  "ancestor"])
def test_rx_handoff(tmp_path: Path, mode: str, case: str) -> None:
    run(tmp_path, mode, case)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", MUTANTS)
def test_rx_handoff_guards(tmp_path: Path, mode: str, mutation: str) -> None:
    run(tmp_path, mode, MUTANTS[mutation], mutation)


def run(tmp_path: Path, mode: str, case: str, mutation: str | None = None) -> None:
    nim = shutil.which("nim")
    if nim is None: pytest.skip("Nim is required")
    path = tmp_path / "rx_handoff.nim"
    text = program(case, mutation)
    # Runtime bounds must be installed before the top-level checks.
    marker = "\nwhen TestCase =="
    text = text.replace(marker, "\nhostStart = cast[uint](addr wifi_hw[0])\nhostEnd = hostStart + sizeof(wifi_hw).uint\n" + marker, 1)
    path.write_text(text)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if mode == "release": command += ["-d:release"]
    if mode == "asan": command += ["--passC:-fsanitize=address", "--passL:-fsanitize=address"]
    command += ["-d:bl808WifiRxPbufInput", "--checks:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", str(path)]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
