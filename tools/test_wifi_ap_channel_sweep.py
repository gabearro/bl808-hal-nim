"""Verify the one-image AP bench gate and its manifest selection."""

import json
from pathlib import Path
from textwrap import dedent

import pytest

from test_wifi_disconnect_tx import ROOT, procedure
from test_wifi_message_allocation import run_program


EXAMPLES = ROOT / "examples"


def sweep_source(example: str) -> str:
    prefix = procedure(example, "requestStartsWith").split("\nwhen defined(bl808WifiApChannelSweep):", 1)[0]
    return prefix + "\n" + (EXAMPLES / "wifi_ap_channel_sweep.nim").read_text()


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ap_sweep_requires_a_matching_probe_and_explicit_advance(tmp_path: Path, mode: str) -> None:
    example = (EXAMPLES / "m0_wifi_http_server.nim").read_text()
    run_program(tmp_path, mode, sweep_source(example) + r'''
proc request(sweep: ApChannelSweep; client: int; methodAndPath: string): ApSweepReply =
  var data: seq[byte]
  for ch in methodAndPath: data.add(ch.byte)
  apSweepRequest(sweep, client.uint, data)

var sweep: ApChannelSweep
doAssert request(sweep, 1, "GET /bench/channel/1 HTTP/1.1\r\n") == apSweepReject
let now = high(uint32) - 10'u32
for channel in ApSweepFirstChannel .. ApSweepLastChannel:
  apSweepOpen(sweep, channel)
  let path = "/bench/channel/" & $channel & " HTTP/1.1\r\n"
  let get = "GET " & path
  let post = "POST " & path
  doAssert not apSweepAdvanceDue(sweep, now)
  doAssert request(sweep, channel, post) == apSweepReject
  doAssert request(sweep, channel - 1, get) == apSweepReject
  doAssert request(sweep, channel, "GET / HTTP/1.1\r\n") == apSweepReject
  doAssert request(sweep, channel, "GET /bench/channel/" & $(channel + 1) & " HTTP/1.1\r\n") == apSweepReject
  doAssert request(sweep, channel, "GET /bench/channel/" & $channel & " HTTP/1.") == apSweepReject
  doAssert request(sweep, channel, get) == apSweepProbe
  # A parsed request whose write/output failed does not unlock the next step.
  doAssert request(sweep, channel, post) == apSweepReject
  apSweepResponseQueued(sweep, apSweepProbe, now)
  doAssert request(sweep, channel - 1, post) == apSweepReject
  doAssert request(sweep, channel, post) == apSweepAdvance
  doAssert not apSweepAdvanceDue(sweep, now)
  apSweepResponseQueued(sweep, apSweepAdvance, now)
  doAssert request(sweep, channel, post) == apSweepReject
  doAssert not apSweepAdvanceDue(sweep, 988)
  doAssert apSweepAdvanceDue(sweep, 989)
  sweep.ready = false
  doAssert not apSweepAdvanceDue(sweep, 989)

doAssert apSweepSsid("bench", 1) == "bench-ch01"
doAssert apSweepSsid("bench", 11) == "bench-ch11"
''')


def test_ap_sweep_reuses_listener_and_restarts_ap_in_order(tmp_path: Path) -> None:
    example = (EXAMPLES / "m0_wifi_http_server.nim").read_text()
    ap_start = example.index("\n  proc startApHttpSmoke(")
    sweep_start = example.index("\n    proc startApSweepChannel(", ap_start)
    start_end = example.index("\n  when defined(bl808WifiApChannelSweep):", ap_start)
    sweep_end = example.index("\nproc connectWifiAndDhcp(", sweep_start)
    handlers = dedent(example[ap_start:start_end]) + dedent(example[sweep_start:sweep_end])
    platform = r'''
type
  Phase = enum auth, scan
  Kind = enum ok, fail, info
  WifiError = enum wifiOk, wifiFail
  Netif = object
  TcpPcb = object
const
  WifiSsid = "Bench"
  WifiPassword = "bench-only"
  HttpPort = 80
  ErrOk = 0.cint
  ApIp = 0x010BA8C0'u32
var
  apChannelSweep: ApChannelSweep
  apFirmwareTiming = [0'u32, 1, 31]
  apHostTiming = [0'u32, 0, 0, 0, 1, 101]
  console: int
  ap, station: Netif
  listener: TcpPcb
  listenPcb: ptr TcpPcb
  httpLastIp, timeMs: uint32
  starts, stops, leases, binds, closes: int
  radioUp, dhcpUp, failDhcpStop: bool
  messages: seq[string]
template phaseMark(p: Phase; k: Kind; body: untyped) = discard
proc sendLine(console: int; msg: string): bool =
  messages.add(msg)
  true
proc nowMs(): uint32 = timeMs
proc wifiGetNetif(): pointer = addr station
proc wifiGetApNetif(): pointer =
  if radioUp: addr ap else: nil
proc netifIp4(netif: ptr Netif): uint32 =
  doAssert netif == addr ap
  ApIp
proc wifiStartAp(ssid, password: string; channel: int): WifiError =
  doAssert not radioUp and not dhcpUp and starts == stops
  doAssert channel == starts + 1 and ssid == apSweepSsid(WifiSsid, channel)
  inc starts
  radioUp = true
  wifiOk
proc wifiStopAp(): WifiError =
  doAssert radioUp and not dhcpUp
  inc stops
  radioUp = false
  wifiOk
proc ip4Addr(a, b, c, d: int): uint32 = d.uint32
proc dhcpServerStart(netif: ptr Netif; first, last: ptr uint32): cint =
  doAssert netif == (addr ap) and radioUp and not dhcpUp
  doAssert first[] == 20 and last[] == 23
  dhcpUp = true
  inc leases
  ErrOk
proc dhcpServerStop(netif: ptr Netif): cint =
  doAssert netif == (addr ap) and radioUp and dhcpUp
  if failDhcpStop: return -1
  dhcpUp = false
  ErrOk
proc startHttpServer(port: uint16; address: uint32): bool =
  doAssert radioUp and dhcpUp and listenPcb == nil and address == ApIp and port == 80
  inc binds
  listenPcb = addr listener
  true
proc tcpClose(pcb: ptr TcpPcb): cint =
  doAssert pcb == (addr listener) and not radioUp and not dhcpUp
  inc closes
  ErrOk
'''
    run_program(tmp_path, "checked", sweep_source(example) + platform + handlers + r'''
doAssert startApSweepChannel(ApSweepFirstChannel)
for channel in ApSweepFirstChannel .. ApSweepLastChannel:
  doAssert apChannelSweep.channel == channel and apChannelSweep.ready
  doAssert starts == channel and stops == channel - 1 and leases == channel
  doAssert binds == 1 and closes == 0 and radioUp and dhcpUp
  apSweepResponseQueued(apChannelSweep, apSweepProbe, timeMs)
  apSweepResponseQueued(apChannelSweep, apSweepAdvance, timeMs)
  timeMs += ApSweepAdvanceDelayMs - 1
  apSweepTick()
  doAssert starts == channel and stops == channel - 1
  inc timeMs
  apSweepTick()
  doAssert stops == channel
doAssert not radioUp and not dhcpUp and listenPcb == nil and closes == 1
doAssert messages[^1] == "[PASS] AP channel sweep complete"

starts = 0
stops = 0
failDhcpStop = true
doAssert startApSweepChannel(ApSweepFirstChannel)
apSweepResponseQueued(apChannelSweep, apSweepProbe, timeMs)
apSweepResponseQueued(apChannelSweep, apSweepAdvance, timeMs)
timeMs += ApSweepAdvanceDelayMs
apSweepTick()
doAssert starts == 1 and stops == 0 and radioUp and dhcpUp and not apChannelSweep.ready
doAssert messages[^1] == "[FAIL] AP sweep stop"
''')


def test_ap_sweep_is_a_separate_manual_image() -> None:
    manifest = json.loads((ROOT / "tools/hardware_validation.json").read_text())
    tests = {entry["name"]: entry for entry in manifest["tests"]}
    sweep = tests["m0_wifi_ap_channel_sweep"]
    build, = sweep["build"]
    assert sweep["tiers"] == ["manual"] and build["flash"] == "m0"
    assert build["defines"]["bl808WifiApHttpSmoke"] == "1"
    assert build["defines"]["bl808WifiApChannelSweep"] == "1"
    assert build["defines"]["WifiPassword"]["secret_env"] == "BL808_WIFI_AP_BENCH_PASSWORD"
    assert "bl808WifiApChannelSweep" not in tests["m0_wifi_ap_http_smoke"]["build"][0]["defines"]
    assert sweep["required"] == ["[PASS] AP channel sweep complete"]
