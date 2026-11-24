"""Run the opt-in STA experiment scheduler against a fake clock and Wi-Fi."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import ROOT
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/tables
type
  Netif = object
    ip: uint32
  Phase {.pure.} = enum scan
  Kind {.pure.} = enum info
var
  net = Netif(ip: 0x7201A8C0)
  clock: uint32
  httpLastIp = net.ip
  httpRequests, udpRxPackets, done, results, lastReason: uint32
  wifiScanAbHome: array[7, uint32]
  log: seq[Table[string, string]]
  connected = true
  dropOnSubmit: bool
  submits = 0
  submitStatus: cint
  confirmStatus: uint32
proc nowMs(): uint32 = clock
proc wifiGetNetif(): pointer = addr net
proc netifIp4(n: ptr Netif): uint32 = n.ip
proc wifiScanAbWpaState(): uint32 = (if connected: 10'u32 else: 0'u32)
proc wifiScanAbConfirmStatus(): uint32 = confirmStatus
proc bl808_wifi_backend_connected(): cint = connected.cint
proc bl808_wifi_backend_last_status(): cint = (if connected: 0 else: 7)
proc bl808_wifi_backend_last_reason(): uint32 = lastReason
proc bl808_wifi_backend_scan_done_count(): uint32 = done
proc bl808_wifi_backend_scan_count(): uint32 = results
proc wifi_mgmr_scan(iface, callback: pointer): cint =
  inc submits
  done = 0
  if dropOnSubmit:
    connected = false
    lastReason = 7
    clock += 5
  submitStatus
template phaseMark(phase: Phase; kind: Kind; body: untyped) =
  log.add(initTable[string, string]())
  body
template kvWrite(key: string; value: untyped) = log[^1][key] = $value
'''


CASES = {
    "balanced_wrap": r'''
clock = high(uint32) - WifiScanAbWarmupMs div 2
var bench = ScanAbBench(readyAt: clock)
clock += WifiScanAbWarmupMs - 1
scanAbTick(bench)
doAssert log.len == 0
inc clock
for index, scan in [false, true, true, false]:
  done = 12 # A previous confirmation must not count in this window.
  let previous = submits
  scanAbTick(bench)
  doAssert log[^1]["event"] == "window_start" and log[^1]["scan"] == $scan.uint32
  doAssert submits == previous + scan.int
  inc httpRequests, 3
  inc udpRxPackets, 5
  if scan:
    inc clock
    inc wifiScanAbHome[0]
    wifiScanAbHome[1] = 1337
    inc wifiScanAbHome[2]
    inc wifiScanAbHome[3]
    wifiScanAbHome[6] = 0x80800000'u32
    done = 1
    results = 4
    scanAbTick(bench)
    doAssert log[^1]["event"] == "scan_confirm" and log[^1]["results"] == "4"
  clock = bench.windowAt + WifiScanAbWindowMs
  scanAbTick(bench)
  let record = log[if index == 3: log.high - 1 else: log.high]
  doAssert record["event"] == "window_end" and record["outcome"] == "complete"
  doAssert record["http"] == "3" and record["udp_rx"] == "5"
  doAssert record["home_ack"] == $scan.uint32 and record.hasKey("first_home_ms") == scan
doAssert submits == 2 and bench.stopped and log[^1]["windows"] == "4"
let length = log.len
scanAbTick(bench)
doAssert log.len == length
''',
    "stop_on_link_loss": r'''
var bench = ScanAbBench(readyAt: 0)
clock = WifiScanAbWarmupMs
scanAbTick(bench)
clock += WifiScanAbWindowMs
scanAbTick(bench)
scanAbTick(bench)
doAssert submits == 1
clock += 10
connected = false
lastReason = 7
scanAbTick(bench)
doAssert bench.stopped and log[^2]["scan"] == "1"
doAssert log[^2]["outcome"] == "link_lost" and log[^2]["reason"] == "7"
doAssert log[^1]["event"] == "finished" and log[^1]["windows"] == "2"
let length = log.len
clock += WifiScanAbWindowMs
scanAbTick(bench)
doAssert submits == 1 and log.len == length
''',
    "incomplete_scan": r'''
var bench = ScanAbBench(readyAt: 0, window: 1)
clock = WifiScanAbWarmupMs
scanAbTick(bench)
doAssert submits == 1 and not bench.confirmed
clock += WifiScanAbWindowMs
scanAbTick(bench)
doAssert bench.stopped and log[^1]["outcome"] == "scan_timeout"
''',
    "submission_rejected": r'''
var bench = ScanAbBench(readyAt: 0, window: 1)
clock = WifiScanAbWarmupMs
submitStatus = -16
done = 1
scanAbTick(bench)
doAssert submits == 1 and not bench.confirmed and not bench.submitted
doAssert log[^3]["event"] == "submit_rejected" and log[^3]["rc"] == "-16"
doAssert bench.stopped and log[^1]["outcome"] == "submit_rejected"
''',
    "disconnect_during_submission": r'''
var bench = ScanAbBench(readyAt: 0, window: 1)
clock = WifiScanAbWarmupMs
submitStatus = -16
dropOnSubmit = true
scanAbTick(bench)
doAssert submits == 1 and bench.stopped
doAssert log[^3]["event"] == "submit_rejected" and log[^3]["rc"] == "-16"
doAssert log[^2]["outcome"] == "link_lost" and log[^2]["reason"] == "7"
doAssert log[^2]["ms"] == $clock
''',
    "failed_confirmation": r'''
var bench = ScanAbBench(readyAt: 0, window: 1)
clock = WifiScanAbWarmupMs
scanAbTick(bench)
done = 1
confirmStatus = 6
scanAbTick(bench)
doAssert submits == 1 and bench.stopped
doAssert log[^3]["event"] == "scan_confirm" and log[^3]["status"] == "6"
doAssert log[^1]["outcome"] == "scan_failed"
''',
    "address_changed_in_control": r'''
var bench = ScanAbBench(readyAt: 0)
clock = WifiScanAbWarmupMs
scanAbTick(bench)
net.ip = 0
scanAbTick(bench)
doAssert submits == 0 and bench.stopped
doAssert log[^2]["outcome"] == "lease_changed" and log[^2]["scan"] == "0"
''',
}


@pytest.mark.parametrize("case", CASES)
def test_scan_ab_bench(tmp_path: Path, case: str) -> None:
    source = (ROOT / "examples/wifi_scan_ab_bench.nim").read_text()
    run_program(tmp_path, "checked", PLATFORM + source + CASES[case])
