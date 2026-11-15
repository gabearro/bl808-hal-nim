"""Propagate a failed MAC initialization through MM and startup callers."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_main_startup import backend_source, source as main_source
from test_wifi_message_allocation import run_program
from test_wifi_mm_reset import source as reset_source


MAC_PLATFORM = r'''
import std/tables
var
  registers = initTable[uint, uint32]()
  writes: seq[tuple[address: uint, value: uint32]]
  calls: seq[string]
  ready: bool
  pending: uint32
  diagnostics: int
  tx: tuple[resetInProgress: uint8]
  fw_nap_chain: array[8, uint8]
  fw_nap_chain_ptr: pointer
  bl_env: array[2, uint32]
proc regRead(address: uint): uint32 = registers.getOrDefault(address)
proc regWrite(address: uint; value: uint32) =
  registers[address] = value
  writes.add((address, value))
proc waitMacSoftResetClear(): bool = ready
proc txControlEnv(): ptr typeof(tx) = addr tx
proc ke_evt_set(mask: uint32) = pending = pending or mask
proc assert_err(condition, file: cstring; line: cint) = inc diagnostics
proc nimFwTrace(message: string) = discard
proc phy_get_mac_freq(): uint32 =
  calls.add("clock")
  40
proc phy_get_ntx(): uint8 =
  calls.add("chains")
  0
proc bl808ApplyPureRfMacTimingBaseline() = calls.add("rf-baseline")
proc me_init() = calls.add("me")
proc mm_env_init() = calls.add("mm-env")
proc vif_mgmt_init(): bool =
  calls.add("vif")
  true
proc sta_mgmt_init() = calls.add("sta")
proc td_init() = calls.add("td")
proc ps_init() = calls.add("ps")
proc txl_cntrl_init() =
  calls.add("tx")
  tx.resetInProgress = 0
proc rxl_init(): bool =
  calls.add("rx")
  true
proc mm_timer_init() = calls.add("timer")
proc scan_init() = calls.add("scan")
proc chan_init() = calls.add("chan")
proc mm_bcn_init() = calls.add("beacon")
proc ke_init() =
  calls.add("ke")
  pending = 0
proc bl_supplicant_init() = calls.add("supplicant")
proc setupMac(success: bool) =
  ready = success
  calls.setLen(0)
  writes.setLen(0)
  registers.clear()
  registers[MACHW_BASE + 0xE4] = 40
  registers[MACHW_BASE + 0xD8] = 0x0C000000'u32
  registers[MACHW_INTC_UNMASK_REG] = 0xFFFFFFFF'u32
  registers[MACHW_INTC_GEN_STATUS] = 0xFFFFFFFF'u32
  pending = 0
  diagnostics = 0
  tx.resetInProgress = 0
'''


def mac_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    registers = (FW / "register_constants.nim").read_text().split("\nwhen defined", 1)[0]
    interrupt_constants = re.findall(r"^  MACHW_INTC_.*$", kernel, re.M)
    code = registers + "\nconst\n" + "\n".join(interrupt_constants) + "\n"
    code += MAC_PLATFORM + procedure(kernel, "hal_machw_disable_int")
    code += procedure(kernel, "hal_machw_init") + procedure(kernel, "mm_init")
    return code + procedure((FW / "platform_bl.nim").read_text(), "bl_init")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_failed_mac_init_stops_platform_initialization(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, mac_source() + r'''
setupMac(false)
bl_init()
doAssert calls == @["me"]
doAssert pending == 0x80000000'u32 and tx.resetInProgress == 1
doAssert writes == @[
  (MACHW_INTC_SOFT_RESET, 1'u32),
  (MACHW_INTC_UNMASK_REG, 0x7FFFFFFF'u32),
  (MACHW_INTC_GEN_STATUS, 0x7FFFFFFF'u32)]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mac_initialization_retry_preserves_success_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, mac_source() + r'''
setupMac(false)
doAssert not mm_init()
doAssert calls.len == 0 and tx.resetInProgress == 1
ready = true
calls.setLen(0)
doAssert bl_init()
doAssert calls == @["me", "clock", "chains", "rf-baseline", "mm-env", "vif",
  "sta", "td", "ps", "tx", "rx", "timer", "scan", "chan", "beacon", "ke", "supplicant"]
doAssert diagnostics == 0 and pending == 0 and tx.resetInProgress == 0
doAssert fw_nap_chain_ptr == cast[pointer](addr fw_nap_chain[0])
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_request_does_not_confirm_failed_initialization(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, reset_source() + r'''
for enabled in [false, true]:
  setup(enabled)
  failInitResult = true
  doAssert mm_reset_req_handler(addr message.payload[0]) == KeMsgSaved
  doAssert confirmations.len == 0 and mmState == 255
  doAssert interrupts == enabled and irqDepth == 0
  doAssert events == @["disable", "mac-stop", "phy-stop", "me-init", "mm-init", "restore"]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_firmware_entry_does_not_start_after_init_failure(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, main_source() + r'''
for enabled in [false, true]:
  setup(enabled, true, 0xA5A50121'u32)
  blReady = false
  wifi_main(nil)
  doAssert serviceCalls == 0 and interrupts == enabled
  doAssert "pm" notin steps and "timing" notin steps
  doAssert messages[^1] == (301.cint, "MAC initialization failed\r\n")
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_backend_firmware_start_returns_failure_and_retries(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, backend_source() + r'''
for enabled in [false, true]:
  setup(enabled, false, 0xA5A50121'u32)
  fwStarted = false
  blReady = false
  doAssert not bl808WifiBackendFwStart()
  doAssert not fwStarted and interrupts == enabled
  doAssert "pm" notin steps and "timing" notin steps
  blReady = true
  doAssert bl808WifiBackendFwStart() and fwStarted
  let before = steps
  doAssert bl808WifiBackendFwStart()
  doAssert steps == before
''')


API_PLATFORM = r'''
type
  WifiConf = object
    country: array[8, uint8]
  WifiMgmr = object
    bytes: array[128, uint8]
const
  WifiConfCountryOff = 0
  MgmrReadyOff = 0
  MgmrApBcnIntOff = 2
  MgmrApInfoTtlOff = 4
  MgmrScanItemTimeoutOff = 8
  MgmrScanItemsLockOff = 16
  MgmrStatInfoOff = 24
  StatDiagnoseLockOff = 0
  StatDiagnoseGetLockOff = 8
  WifiMgmrConfigScanItemTimeout = 1000
var
  manager: WifiMgmr
  wifiStarted, fwStarted, hostPollEnabled, fwReady, wifiInitialized: bool
  connectCb, disconnectCb, beaconCb, eventCb: pointer
  calls: seq[string]
  readyByte: uint8
proc mgmrRaw(): pointer = addr manager
proc zero(p: pointer; size: uint) =
  zeroMem(p, size.int)
  if p == (addr manager): readyByte = 0
proc loadU8(p: pointer; offset: int): uint8 =
  cast[ptr UncheckedArray[uint8]](p)[offset]
proc storeU8(p: pointer; offset: int; value: uint8) =
  if p == (addr manager) and offset == MgmrReadyOff: readyByte = value
proc storeU16(p: pointer; offset: int; value: uint16) = discard
proc storeI32(p: pointer; offset: int; value: int32) = discard
proc storePtr(p: pointer; offset: int; value: pointer) = discard
proc ptrAt(p: pointer; offset: int): pointer = cast[pointer](cast[uint](p) + offset.uint)
proc osMutexCreate(): pointer =
  calls.add("mutex")
  nil
proc setupBlOps() = discard
proc setupHosal() = discard
proc bl808WifiBackendTrace(message: cstring) = discard
proc bl808WifiBackendFwStart(): bool =
  calls.add("firmware")
  fwStarted = fwReady
  fwReady
proc bl606a0_wifi_init(conf: ptr WifiConf): cint =
  calls.add("host")
  doAssert conf.country[0] == 'U'.uint8 and conf.country[1] == 'S'.uint8
  0
proc bl_main_phy_up(): cint =
  calls.add("phy")
  0
proc vendorPollFor(ms: uint32) = calls.add("poll")
proc bl_rx_sm_connect_ind_cb_register(env, callback: pointer): cint =
  calls.add("connect")
  0
proc bl_rx_sm_disconnect_ind_cb_register(env, callback: pointer): cint =
  calls.add("disconnect")
  0
proc bl_rx_beacon_ind_cb_register(env, callback: pointer): cint =
  calls.add("beacon")
  0
proc bl_rx_event_register(env, callback: pointer): cint =
  calls.add("event")
  0
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_public_backend_rejects_failed_firmware_start(tmp_path: Path, mode: str) -> None:
    implementation = procedure(
        (FW.parent / "support/mgmr_facade_parts/backend_init.nim").read_text(),
        "bl808_wifi_backend_init",
    )
    facade = procedure(
        (FW.parent / "facade_parts/backend_imports_parts/backend_core.nim").read_text(),
        "wifi_mgmr_init",
    )
    run_program(tmp_path, mode, API_PLATFORM + implementation + facade + r'''
fwReady = false
hostPollEnabled = true
readyByte = 1
wifiInitialized = true
doAssert wifi_mgmr_init(nil) != 0
doAssert not fwStarted and not wifiStarted and not hostPollEnabled and not wifiInitialized
doAssert readyByte == 0 and calls == @["firmware"]
fwReady = true
calls.setLen(0)
doAssert wifi_mgmr_init(nil) == 0
doAssert fwStarted and wifiStarted and hostPollEnabled and readyByte == 1 and wifiInitialized
doAssert calls == @["firmware", "host", "phy", "poll", "mutex", "mutex",
                   "mutex", "connect", "disconnect", "beacon", "event"]
let before = calls
doAssert wifi_mgmr_init(nil) == 0 and calls == before
''')
