"""Replay scan-ring evidence used by the standalone Wi-Fi HTTP bench."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_http_scan_evidence(tmp_path: Path, mode: str) -> None:
    diag = (ROOT / "src/bl808/wifi/support/scan_diag.nim").read_text()
    example = (ROOT / "examples/m0_wifi_http_server.nim").read_text()
    platform = r'''
type
  Phase = enum scan
  Kind = enum ok
  ScanDiagItem = object
    used, ssidLen: uint8
    ssid: array[33, uint8]
    bssid: array[6, uint8]
    channel: uint8
    rssi: int8
    auth, cipher: uint8
  Beacon = object
    ssidLen: int32
    item: ScanDiagItem
const
  VendorScanDiagMax = 4
  WifiBeaconSsidLenOff = offsetof(Beacon, ssidLen).uint
  WifiBeaconSsidOff = (offsetof(Beacon, item) + offsetof(ScanDiagItem, ssid)).uint
  WifiBeaconBssidOff = (offsetof(Beacon, item) + offsetof(ScanDiagItem, bssid)).uint
  WifiBeaconChannelOff = (offsetof(Beacon, item) + offsetof(ScanDiagItem, channel)).uint
  WifiBeaconRssiOff = (offsetof(Beacon, item) + offsetof(ScanDiagItem, rssi)).uint
  WifiBeaconAuthOff = (offsetof(Beacon, item) + offsetof(ScanDiagItem, auth)).uint
  WifiBeaconCipherOff = (offsetof(Beacon, item) + offsetof(ScanDiagItem, cipher)).uint
var
  scanDiag: array[VendorScanDiagMax, ScanDiagItem]
  scanItemCount, reportedChannel: uint32
  joinedBssid: array[6, uint8]
  assocResult: cint
template phaseMark(p: Phase; k: Kind; body: untyped) = body
template kvWrite(key: static[string]; value: uint32) =
  when key == "ch": reportedChannel = value
proc ptrAt(p: pointer; offs: uint): pointer = cast[pointer](cast[uint](p) + offs)
proc loadU8(p: pointer; offs: uint): uint8 = cast[ptr uint8](ptrAt(p, offs))[]
proc loadI8(p: pointer; offs: uint): int8 = cast[ptr int8](ptrAt(p, offs))[]
proc loadI32(p: pointer; offs: uint): int32 = cast[ptr int32](ptrAt(p, offs))[]
proc zero(p: pointer; count: uint) = zeroMem(p, count.int)
proc bl808_wifi_backend_scan_count(): uint32 = scanItemCount
proc bl808_wifi_backend_scan_done_count(): uint32 = 1
proc bl_wifi_get_assoc_bssid_internal(vif: uint8; bssid: pointer): cint =
  doAssert vif == 0
  cast[ptr array[6, uint8]](bssid)[] = joinedBssid
  assocResult
'''
    handlers = "".join(procedure(diag, name) for name in (
        "scanDiagStore", "bl808_wifi_backend_scan_diag_count", "bl808_wifi_backend_scan_diag_get",
    )) + procedure(example, "scanDiagHasFreshResult")
    run_program(tmp_path, mode, platform + handlers + r'''
const
  peer = [2'u8, 3, 4, 5, 6, 7]
  other = [4'u8, 3, 4, 5, 6, 7]
proc observe(ssid: string; bssid: array[6, uint8]; channel: uint8) =
  var record = Beacon(ssidLen: ssid.len.int32)
  record.item.bssid = bssid
  record.item.channel = channel
  for i in 0 ..< ssid.len: record.item.ssid[i] = ssid[i].uint8
  scanDiagStore(addr record)

joinedBssid = peer
observe("Bench", peer, 6)
let initial = scanItemCount
doAssert initial == 1
doAssert not scanDiagHasFreshResult(initial, "Bench", 6)

observe("Bench", other, 1)
observe("Other", peer, 1)
observe("Bench", peer, 0)
doAssert not scanDiagHasFreshResult(initial, "Bench", 1)
doAssert not scanDiagHasFreshResult(initial, "Bench")

let full = scanItemCount
scanDiagStore(nil)
var bad = Beacon(ssidLen: 33)
scanDiagStore(addr bad)
doAssert scanItemCount == full
doAssert not scanDiagHasFreshResult(full, "Bench")

observe("Bench", peer, 6)
doAssert not scanDiagHasFreshResult(full, "Bench", 1)
doAssert not scanDiagHasFreshResult(full, "bench", 6)
doAssert scanDiagHasFreshResult(full, "Bench", 6) and reportedChannel == 6
let before = scanItemCount
for _ in 1 .. VendorScanDiagMax: observe("Bench", other, 6)
doAssert not scanDiagHasFreshResult(full, "Bench", 6)
observe("Bench", peer, 11)
doAssert scanDiagHasFreshResult(before, "Bench") and reportedChannel == 11

assocResult = -1
doAssert not scanDiagHasFreshResult(before, "Bench")
assocResult = 0
for unbound in [[0'u8, 0, 0, 0, 0, 0], [0xFF'u8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]]:
  joinedBssid = unbound
  observe("Bench", unbound, 11)
  doAssert not scanDiagHasFreshResult(before, "Bench")
joinedBssid = peer
scanItemCount = 0
doAssert not scanDiagHasFreshResult(before, "Bench")
''')
